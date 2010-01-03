require "mkmf"

have_header("sys/select.h")
have_header("signal.h")
have_header("mqueue.h") or abort "mqueue.h header missing"
have_func("rb_str_set_len")
have_func("rb_struct_alloc_noinit")
have_func('rb_thread_blocking_region')
have_library("rt")
dir_config("posix_mq")
create_makefile("posix_mq_ext")
