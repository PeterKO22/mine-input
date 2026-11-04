/* Shift 中/英切换探针 v3：RIME_STRUCT 即声明，模拟真实前端 down/up 序列 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <rime_api.h>

#ifndef kReleaseMask
#define kReleaseMask (1 << 30)
#endif

static RimeApi* rime;

static int is_ascii(RimeSessionId s) {
  RIME_STRUCT(RimeStatus, st);
  rime->get_status(s, &st);
  int v = st.is_ascii_mode;
  rime->free_status(&st);
  return v;
}
static void press_shift(RimeSessionId s) {
  const int XK_Shift_L = 0xffe1;
  rime->process_key(s, XK_Shift_L, 0);
  rime->process_key(s, XK_Shift_L, kReleaseMask);
}

int main(void) {
  /* W21 脱敏：RIME 用户目录取 $HOME（不再硬编码个人路径） */
  static char rime_dir[512];
  snprintf(rime_dir, sizeof rime_dir, "%s/Library/Rime-mine-dev",
           getenv("HOME") ? getenv("HOME") : ".");
  rime = rime_get_api();
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = rime_dir;
  traits.user_data_dir = rime_dir;
  traits.distribution_name = "MineInputProbe";
  traits.distribution_code_name = "mineinput_probe";
  traits.distribution_version = "0.1";
  traits.app_name = "rime.mineinput-probe";
  rime->setup(&traits);
  rime->initialize(NULL);

  RimeSessionId s = rime->create_session();
  if (!s) { printf("FAIL: no session\n"); return 1; }
  rime->select_schema(s, "ping_wubi_mixed");

  printf("init ascii_mode=%d\n", is_ascii(s));

  press_shift(s);
  printf("[1] after shift -> ascii_mode=%d (期望 1)\n", is_ascii(s));

  int h = rime->process_key(s, 'h', 0);
  int i = rime->process_key(s, 'i', 0);
  printf("[2] ascii 'h','i' ret=%d,%d (期望 0,0 = 透传)\n", h, i);

  press_shift(s);
  printf("[3] 2nd shift -> ascii_mode=%d (期望 0)\n", is_ascii(s));

  rime->process_key(s, 'w', 0);
  {
    RIME_STRUCT(RimeContext, ctx);
    if (rime->get_context(s, &ctx) && ctx.menu.num_candidates > 0)
      printf("[4] 'w' cand1=%s (期望 人)\n", ctx.menu.candidates[0].text);
    else
      printf("[4] FAIL: 无候选\n");
    rime->free_context(&ctx);
  }

  rime->process_key(s, 'g', 0);
  press_shift(s);
  {
    RIME_STRUCT(RimeCommit, commit);
    if (rime->get_commit(s, &commit)) {
      printf("[5] commit='%s' (期望 g 原样上屏)\n", commit.text);
      rime->free_commit(&commit);
    } else {
      printf("[5] FAIL: 无上屏\n");
    }
  }
  printf("[5] ascii_mode=%d (期望 1)\n", is_ascii(s));

  rime->destroy_session(s);
  rime->finalize();
  printf("probe done\n");
  return 0;
}
