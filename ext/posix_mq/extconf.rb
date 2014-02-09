require "mkmf"

have_header("sys/select.h")
have_header("signal.h")
have_header("mqueue.h") or abort "mqueue.h header missing"
have_header("pthread.h")
have_func("rb_str_set_len")
have_func('rb_thread_blocking_region')
have_func('rb_thread_call_without_gvl')
have_library("m")
have_library("rt")
have_library("pthread")

have_func("__mq_oshandle")
have_func("mq_timedsend")
have_func("mq_timedreceive")
create_makefile("posix_mq_ext")
