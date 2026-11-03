"""版本化提示词模板（W10）。

场景对齐 docs/技术方案-v0.4.md §7（场景顺序：语音同音字纠错 → 候选重排 → 续写联想）
与 §8（提词器三唤起）：
  voice_correct  语音同音字纠错（§7 场景 1）
  rescore        候选重排（§7 场景 2）
  continuation   续写联想（§7 场景 3）
  teleprompter   提词（§8 动态提词器）

模板是「AI 配置/提示词模板」同步面的一部分（技术方案 §9），故显式版本化：
PROMPT_VERSION 变更即代表提示词语义变更，会随 /v1/suggest 的 done 帧下发，
便于客户端/服务端对账。渲染用 Qwen2.5 chat 模板（<|im_start|>/<|im_end|>），
llama-server 侧以 raw /completion 接收，模板完全由本文件持有（可审计、可回滚）。
"""

PROMPT_VERSION = "v1.0"

SCENES = ("continuation", "voice_correct", "rescore", "teleprompter")

# 通用约束（所有场景共用，减少模板漂移）
_CONSTRAINTS = (
    "只输出结果本身，不解释、不加引号、不加序号。"
)

SYSTEM_PROMPTS = {
    "continuation": (
        "你是中文输入法的续写引擎。根据用户已输入的文本，续写最可能的后续内容。"
        "输出 20 字以内的自然中文续写，不重复用户已输入的内容。" + _CONSTRAINTS
    ),
    "voice_correct": (
        "你是中文语音输入纠错助手。输入文本来自语音转写，可能存在同音字、近音词错误。"
        "输出纠正后的完整句子，保持原意与口语风格。" + _CONSTRAINTS
    ),
    "rescore": (
        "你是中文输入法候选重排引擎。给定输入上下文与候选列表，按上屏可能性从高到低重排。"
        "必须输出与候选列表相同数量的行，每行输出一个候选，必须原样复制候选文本"
        "（不带行号、不带分数），最可能的在前。" + _CONSTRAINTS
    ),
    "teleprompter": (
        "你是打字提词器。根据当前输入实时给出简短续写提词，不超过 15 字，"
        "口语化、可直接上屏。" + _CONSTRAINTS
    ),
}

_USER_TEMPLATES = {
    "continuation": "已输入：{text}\n续写：",
    # 小模型（≤3B）few-shot 才稳定听指令：纠正/重排各带紧凑示例；7B+ 同样受益
    "voice_correct": (
        "示例：\n"
        "转写文本：我今天去了音行办理信用卡业务\n"
        "纠错结果：我今天去了银行办理信用卡业务\n\n"
        "转写文本：他的声因很好听\n"
        "纠错结果：他的声音很好听\n\n"
        "转写文本：{text}\n"
        "纠错结果："
    ),
    "rescore": (
        "示例：\n"
        "输入上下文：ni hao\n"
        "候选列表：\n1. 你好\n2. 拟好\n3. 泥嚎\n"
        "重排结果：\n你好\n拟好\n泥嚎\n\n"
        "输入上下文：{text}\n"
        "候选列表：\n{cands}\n"
        "重排结果：\n"
    ),
    "teleprompter": "当前输入：{text}\n提词：",
}

# 场景级生成参数覆盖（其余走请求级/默认值）
SCENE_GEN_PARAMS = {
    "continuation": {"temperature": 0.4},
    "voice_correct": {"temperature": 0.1},
    "rescore": {"temperature": 0.0},
    "teleprompter": {"temperature": 0.5},
}


def build_messages(scene: str, before_cursor: str, candidates=()) -> tuple:
    """返回 (system, user) 两段消息文本。scene 非法时按 continuation 处理。"""
    if scene not in SYSTEM_PROMPTS:
        scene = "continuation"
    system = SYSTEM_PROMPTS[scene]
    if scene == "rescore":
        cands = "\n".join(f"{i}. {c}" for i, c in enumerate(candidates, 1)) or "1. （空）"
        user = _USER_TEMPLATES[scene].format(text=before_cursor or "（无）", cands=cands)
    else:
        user = _USER_TEMPLATES[scene].format(text=before_cursor or "（无）")
    return system, user


def render_prompt(scene: str, before_cursor: str, candidates=()) -> str:
    """渲染为 Qwen2.5 chat 模板的完整 prompt（喂 llama.cpp /completion）。"""
    system, user = build_messages(scene, before_cursor, candidates)
    return (
        f"<|im_start|>system\n{system}<|im_end|>\n"
        f"<|im_start|>user\n{user}<|im_end|>\n"
        f"<|im_start|>assistant\n"
    )


# 停止词：Qwen2.5 chat 边界 + 空行（rescore 场景防跑偏）
STOP_SEQUENCES = ["<|im_end|>", "<|im_start|>"]
