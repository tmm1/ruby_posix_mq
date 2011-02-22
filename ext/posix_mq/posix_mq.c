#define _XOPEN_SOURCE 600
#ifdef HAVE_SYS_SELECT_H
#  include <sys/select.h>
#endif
#ifdef HAVE_SIGNAL_H
#  include <signal.h>
#endif
#ifdef HAVE_PTHREAD_H
#  include <pthread.h>
#endif
#include <ruby.h>

#ifndef NUM2TIMET
#  define NUM2TIMET NUM2INT
#endif

#include <time.h>
#include <mqueue.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <errno.h>
#include <assert.h>
#include <unistd.h>
#include <float.h>
#include <math.h>

#if defined(__linux__)
#  define MQD_TO_FD(mqd) (int)(mqd)
#elif defined(HAVE___MQ_OSHANDLE) /* FreeBSD */
#  define MQD_TO_FD(mqd) __mq_oshandle(mqd)
#else
#  define MQ_IO_MARK(mq) ((void)(0))
#  define MQ_IO_SET(mq,val) ((void)(0))
#  define MQ_IO_CLOSE(mq) ((void)(0))
#  define MQ_IO_NIL_P(mq) ((void)(1))
#endif

struct posix_mq {
	mqd_t des;
	struct mq_attr attr;
	VALUE name;
	VALUE thread;
#ifdef MQD_TO_FD
	VALUE io;
#endif
};

#ifdef MQD_TO_FD
#  define MQ_IO_MARK(mq) rb_gc_mark((mq)->io)
#  define MQ_IO_SET(mq,val) do { (mq)->io = (val); } while (0)
#  define MQ_IO_NIL_P(mq) NIL_P((mq)->io)
static int MQ_IO_CLOSE(struct posix_mq *mq)
{
	if (NIL_P(mq->io))
		return 0;

	/* not safe during GC */
	rb_io_close(mq->io);
	mq->io = Qnil;

	return 1;
}
#endif

static VALUE cPOSIX_MQ, cAttr;
static ID id_new, id_kill, id_fileno, id_mul, id_divmod;
static ID id_flags, id_maxmsg, id_msgsize, id_curmsgs;
static ID sym_r, sym_w, sym_rw;
static const mqd_t MQD_INVALID = (mqd_t)-1;

/* Ruby 1.8.6+ macros (for compatibility with Ruby 1.9) */
#ifndef RSTRING_PTR
#  define RSTRING_PTR(s) (RSTRING(s)->ptr)
#endif
#ifndef RSTRING_LEN
#  define RSTRING_LEN(s) (RSTRING(s)->len)
#endif
#ifndef RFLOAT_VALUE
#  define RFLOAT_VALUE(f) (RFLOAT(f)->value)
#endif

#ifndef HAVE_RB_STR_SET_LEN
/* this is taken from Ruby 1.8.7, 1.8.6 may not have it */
#  ifdef RUBINIUS
#    error upgrade Rubinius, rb_str_set_len should be available
#  endif
static void rb_18_str_set_len(VALUE str, long len)
{
	RSTRING(str)->len = len;
	RSTRING(str)->ptr[len] = '\0';
}
#endif /* !defined(HAVE_RB_STR_SET_LEN) */

/* partial emulation of the 1.9 rb_thread_blocking_region under 1.8 */
#ifndef HAVE_RB_THREAD_BLOCKING_REGION
#  include <rubysig.h>
#  define RUBY_UBF_IO ((rb_unblock_function_t *)-1)
typedef void rb_unblock_function_t(void *);
typedef VALUE rb_blocking_function_t(void *);
static VALUE
rb_thread_blocking_region(
	rb_blocking_function_t *func, void *data1,
	rb_unblock_function_t *ubf, void *data2)
{
	VALUE rv;

	assert(RUBY_UBF_IO == ubf && "RUBY_UBF_IO required for emulation");

	TRAP_BEG;
	rv = func(data1);
	TRAP_END;

	return rv;
}
#endif /* ! HAVE_RB_THREAD_BLOCKING_REGION */

/* used to pass arguments to mq_open inside blocking region */
struct open_args {
	int argc;
	const char *name;
	int oflags;
	mode_t mode;
	struct mq_attr attr;
};

/* used to pass arguments to mq_send/mq_receive inside blocking region */
struct rw_args {
	mqd_t des;
	char *msg_ptr;
	size_t msg_len;
	unsigned msg_prio;
	struct timespec *timeout;
};

static void num2timespec(struct timespec *ts, VALUE t)
{
	switch (TYPE(t)) {
	case T_FIXNUM:
	case T_BIGNUM:
		ts->tv_sec = NUM2TIMET(t);
		ts->tv_nsec = 0;
		break;
	case T_FLOAT: {
		double f, d;
		double val = RFLOAT_VALUE(t);

		d = modf(val, &f);
		if (d >= 0) {
			ts->tv_nsec = (long)(d * 1e9 + 0.5);
		} else {
			ts->tv_nsec = (long)(-d * 1e9 + 0.5);
			if (ts->tv_nsec > 0) {
				ts->tv_nsec = 1000000000 - ts->tv_nsec;
				f -= 1;
			}
		}
		ts->tv_sec = (time_t)f;
		if (f != ts->tv_sec)
			rb_raise(rb_eRangeError, "%f out of range", val);
		ts->tv_sec = (time_t)f;
		}
		break;
	default: {
		VALUE f;
		VALUE ary = rb_funcall(t, id_divmod, 1, INT2FIX(1));

		Check_Type(ary, T_ARRAY);

		ts->tv_sec = NUM2TIMET(rb_ary_entry(ary, 0));
		f = rb_ary_entry(ary, 1);
		f = rb_funcall(f, id_mul, 1, INT2FIX(1000000000));
		ts->tv_nsec = NUM2LONG(f);
		}
	}
}

static struct timespec *convert_timeout(struct timespec *dest, VALUE t)
{
	struct timespec ts, now;

	if (NIL_P(t))
		return NULL;

	num2timespec(&ts, t);
	clock_gettime(CLOCK_REALTIME, &now);
	dest->tv_sec = now.tv_sec + ts.tv_sec;
	dest->tv_nsec = now.tv_nsec + ts.tv_nsec;

	if (dest->tv_nsec > 1000000000) {
		dest->tv_nsec -= 1000000000;
		++dest->tv_sec;
	}

	return dest;
}

/* (may) run without GVL */
static VALUE xopen(void *ptr)
{
	struct open_args *x = ptr;
	mqd_t rv;

	switch (x->argc) {
	case 2: rv = mq_open(x->name, x->oflags); break;
	case 3: rv = mq_open(x->name, x->oflags, x->mode, NULL); break;
	case 4: rv = mq_open(x->name, x->oflags, x->mode, &x->attr); break;
	default: rv = MQD_INVALID;
	}

	return (VALUE)rv;
}

/* runs without GVL */
static VALUE xsend(void *ptr)
{
	struct rw_args *x = ptr;

	if (x->timeout)
		return (VALUE)mq_timedsend(x->des, x->msg_ptr, x->msg_len,
		                           x->msg_prio, x->timeout);

	return (VALUE)mq_send(x->des, x->msg_ptr, x->msg_len, x->msg_prio);
}

/* runs without GVL */
static VALUE xrecv(void *ptr)
{
	struct rw_args *x = ptr;

	if (x->timeout)
		return (VALUE)mq_timedreceive(x->des, x->msg_ptr, x->msg_len,
		                              &x->msg_prio, x->timeout);

	return (VALUE)mq_receive(x->des, x->msg_ptr, x->msg_len, &x->msg_prio);
}

/* called by GC */
static void mark(void *ptr)
{
	struct posix_mq *mq = ptr;

	rb_gc_mark(mq->name);
	rb_gc_mark(mq->thread);
	MQ_IO_MARK(mq);
}

/* called by GC */
static void _free(void *ptr)
{
	struct posix_mq *mq = ptr;

	if (mq->des != MQD_INVALID && MQ_IO_NIL_P(mq)) {
		/* we ignore errors when gc-ing */
		mq_close(mq->des);
		errno = 0;
	}
	xfree(ptr);
}

/* automatically called at creation (before initialize) */
static VALUE alloc(VALUE klass)
{
	struct posix_mq *mq;
	VALUE rv = Data_Make_Struct(klass, struct posix_mq, mark, _free, mq);

	mq->des = MQD_INVALID;
	mq->attr.mq_flags = 0;
	mq->attr.mq_maxmsg = 0;
	mq->attr.mq_msgsize = -1;
	mq->attr.mq_curmsgs = 0;
	mq->name = Qnil;
	mq->thread = Qnil;
	MQ_IO_SET(mq, Qnil);

	return rv;
}

/* unwraps the posix_mq struct from self */
static struct posix_mq *get(VALUE self, int need_valid)
{
	struct posix_mq *mq;

	Data_Get_Struct(self, struct posix_mq, mq);

	if (need_valid && mq->des == MQD_INVALID)
		rb_raise(rb_eIOError, "closed queue descriptor");

	return mq;
}

static void check_struct_type(VALUE astruct)
{
	if (CLASS_OF(astruct) == cAttr)
		return;
	astruct = rb_inspect(astruct);
	rb_raise(rb_eTypeError, "not a POSIX_MQ::Attr: %s",
		 StringValuePtr(astruct));
}

static void rstruct2mqattr(struct mq_attr *attr, VALUE astruct, int all)
{
	VALUE tmp;

	check_struct_type(astruct);
	attr->mq_flags = NUM2LONG(rb_funcall(astruct, id_flags, 0));

	tmp = rb_funcall(astruct, id_maxmsg, 0);
	if (all || !NIL_P(tmp))
		attr->mq_maxmsg = NUM2LONG(tmp);

	tmp = rb_funcall(astruct, id_msgsize, 0);
	if (all || !NIL_P(tmp))
		attr->mq_msgsize = NUM2LONG(tmp);

	tmp = rb_funcall(astruct, id_curmsgs, 0);
	if (!NIL_P(tmp))
		attr->mq_curmsgs = NUM2LONG(tmp);
}

/*
 * call-seq:
 *	POSIX_MQ.new(name [, flags [, mode [, mq_attr]])	=> mq
 *
 * Opens a POSIX message queue given by +name+.  +name+ should start
 * with a slash ("/") for portable applications.
 *
 * If a Symbol is given in place of integer +flags+, then:
 *
 * * +:r+ is equivalent to IO::RDONLY
 * * +:w+ is equivalent to IO::CREAT|IO::WRONLY
 * * +:rw+ is equivalent to IO::CREAT|IO::RDWR
 *
 * +mode+ is an integer and only used when IO::CREAT is used.
 * +mq_attr+ is a POSIX_MQ::Attr and only used if IO::CREAT is used.
 * If +mq_attr+ is not specified when creating a queue, then the
 * system defaults will be used.
 *
 * See the manpage for mq_open(3) for more details on this function.
 */
static VALUE init(int argc, VALUE *argv, VALUE self)
{
	struct posix_mq *mq = get(self, 0);
	struct open_args x;
	VALUE name, oflags, mode, attr;

	rb_scan_args(argc, argv, "13", &name, &oflags, &mode, &attr);

	if (TYPE(name) != T_STRING)
		rb_raise(rb_eArgError, "name must be a string");

	switch (TYPE(oflags)) {
	case T_NIL:
		x.oflags = O_RDONLY;
		break;
	case T_SYMBOL:
		if (oflags == sym_r)
			x.oflags = O_RDONLY;
		else if (oflags == sym_w)
			x.oflags = O_CREAT|O_WRONLY;
		else if (oflags == sym_rw)
			x.oflags = O_CREAT|O_RDWR;
		else {
			oflags = rb_inspect(oflags);
			rb_raise(rb_eArgError,
			         "symbol must be :r, :w, or :rw: %s",
				 StringValuePtr(oflags));
		}
		break;
	case T_BIGNUM:
	case T_FIXNUM:
		x.oflags = NUM2INT(oflags);
		break;
	default:
		rb_raise(rb_eArgError, "flags must be an int, :r, :w, or :wr");
	}

	x.name = RSTRING_PTR(name);
	x.argc = 2;

	switch (TYPE(mode)) {
	case T_FIXNUM:
		x.argc = 3;
		x.mode = NUM2UINT(mode);
		break;
	case T_NIL:
		if (x.oflags & O_CREAT) {
			x.argc = 3;
			x.mode = 0666;
		}
		break;
	default:
		rb_raise(rb_eArgError, "mode not an integer");
	}

	switch (TYPE(attr)) {
	case T_STRUCT:
		x.argc = 4;
		rstruct2mqattr(&x.attr, attr, 1);

		/* principle of least surprise */
		if (x.attr.mq_flags & O_NONBLOCK)
			x.oflags |= O_NONBLOCK;
		break;
	case T_NIL:
		break;
	default:
		check_struct_type(attr);
	}

	mq->des = (mqd_t)xopen(&x);
	if (mq->des == MQD_INVALID) {
		if (errno == ENOMEM || errno == EMFILE || errno == ENFILE) {
			rb_gc();
			mq->des = (mqd_t)xopen(&x);
		}
		if (mq->des == MQD_INVALID)
			rb_sys_fail("mq_open");
	}

	mq->name = rb_str_dup(name);
	if (x.oflags & O_NONBLOCK)
		mq->attr.mq_flags = O_NONBLOCK;

	return self;
}

/*
 * call-seq:
 *	POSIX_MQ.unlink(name) =>	1
 *
 * Unlinks the message queue given by +name+.  The queue will be destroyed
 * when the last process with the queue open closes its queue descriptors.
 */
static VALUE s_unlink(VALUE self, VALUE name)
{
	mqd_t rv;

	if (TYPE(name) != T_STRING)
		rb_raise(rb_eArgError, "argument must be a string");

	rv = mq_unlink(RSTRING_PTR(name));
	if (rv == MQD_INVALID)
		rb_sys_fail("mq_unlink");

	return INT2NUM(1);
}

/*
 * call-seq:
 *	mq.unlink =>	mq
 *
 * Unlinks the message queue to prevent other processes from accessing it.
 * All existing queue descriptors to this queue including those opened by
 * other processes are unaffected.  The queue will only be destroyed
 * when the last process with open descriptors to this queue closes
 * the descriptors.
 */
static VALUE _unlink(VALUE self)
{
	struct posix_mq *mq = get(self, 0);
	mqd_t rv;

	assert(TYPE(mq->name) == T_STRING && "mq->name is not a string");

	rv = mq_unlink(RSTRING_PTR(mq->name));
	if (rv == MQD_INVALID)
		rb_sys_fail("mq_unlink");

	return self;
}

static void setup_send_buffer(struct rw_args *x, VALUE buffer)
{
	buffer = rb_obj_as_string(buffer);
	x->msg_ptr = RSTRING_PTR(buffer);
	x->msg_len = (size_t)RSTRING_LEN(buffer);
}

/*
 * call-seq:
 *	mq.send(string [,priority[, timeout]])	=> nil
 *
 * Inserts the given +string+ into the message queue with an optional,
 * unsigned integer +priority+.  If the optional +timeout+ is specified,
 * then Errno::ETIMEDOUT will be raised if the operation cannot complete
 * before +timeout+ seconds has elapsed.  Without +timeout+, this method
 * may block until the queue is writable.
 */
static VALUE _send(int argc, VALUE *argv, VALUE self)
{
	struct posix_mq *mq = get(self, 1);
	struct rw_args x;
	VALUE buffer, prio, timeout;
	mqd_t rv;
	struct timespec expire;

	rb_scan_args(argc, argv, "12", &buffer, &prio, &timeout);

	setup_send_buffer(&x, buffer);
	x.des = mq->des;
	x.timeout = convert_timeout(&expire, timeout);
	x.msg_prio = NIL_P(prio) ? 0 : NUM2UINT(prio);

	if (mq->attr.mq_flags & O_NONBLOCK)
		rv = (mqd_t)xsend(&x);
	else
		rv = (mqd_t)rb_thread_blocking_region(xsend, &x,
		                                      RUBY_UBF_IO, 0);
	if (rv == MQD_INVALID)
		rb_sys_fail("mq_send");

	return Qnil;
}

/*
 * call-seq:
 *	mq << string	=> mq
 *
 * Inserts the given +string+ into the message queue with a
 * default priority of 0 and no timeout.
 */
static VALUE send0(VALUE self, VALUE buffer)
{
	struct posix_mq *mq = get(self, 1);
	struct rw_args x;
	mqd_t rv;

	setup_send_buffer(&x, buffer);
	x.des = mq->des;
	x.timeout = NULL;
	x.msg_prio = 0;

	if (mq->attr.mq_flags & O_NONBLOCK)
		rv = (mqd_t)xsend(&x);
	else
		rv = (mqd_t)rb_thread_blocking_region(xsend, &x,
		                                      RUBY_UBF_IO, 0);

	if (rv == MQD_INVALID)
		rb_sys_fail("mq_send");

	return self;
}

#ifdef MQD_TO_FD
/*
 * call-seq:
 *	mq.to_io	=> IO
 *
 * Returns an IO.select-able +IO+ object.  This method is only available
 * under Linux and FreeBSD and is not intended to be portable.
 */
static VALUE to_io(VALUE self)
{
	struct posix_mq *mq = get(self, 1);
	int fd = MQD_TO_FD(mq->des);

	if (NIL_P(mq->io))
		mq->io = rb_funcall(rb_cIO, id_new, 1, INT2NUM(fd));

	return mq->io;
}
#endif

static VALUE _receive(int wantarray, int argc, VALUE *argv, VALUE self);

/*
 * call-seq:
 *	mq.receive([buffer, [timeout]])		=> [ message, priority ]
 *
 * Takes the highest priority message off the queue and returns
 * an array containing the message as a String and the Integer
 * priority of the message.
 *
 * If the optional +buffer+ is present, then it must be a String
 * which will receive the data.
 *
 * If the optional +timeout+ is present, then it may be a Float
 * or Integer specifying the timeout in seconds.  Errno::ETIMEDOUT
 * will be raised if +timeout+ has elapsed and there are no messages
 * in the queue.
 */
static VALUE receive(int argc, VALUE *argv, VALUE self)
{
	return _receive(1, argc, argv, self);
}

/*
 * call-seq:
 *	mq.shift([buffer, [timeout]])		=> message
 *
 * Takes the highest priority message off the queue and returns
 * the message as a String.
 *
 * If the optional +buffer+ is present, then it must be a String
 * which will receive the data.
 *
 * If the optional +timeout+ is present, then it may be a Float
 * or Integer specifying the timeout in seconds.  Errno::ETIMEDOUT
 * will be raised if +timeout+ has elapsed and there are no messages
 * in the queue.
 */
static VALUE shift(int argc, VALUE *argv, VALUE self)
{
	return _receive(0, argc, argv, self);
}

static VALUE _receive(int wantarray, int argc, VALUE *argv, VALUE self)
{
	struct posix_mq *mq = get(self, 1);
	struct rw_args x;
	VALUE buffer, timeout;
	ssize_t r;
	struct timespec expire;

	if (mq->attr.mq_msgsize < 0) {
		if (mq_getattr(mq->des, &mq->attr) < 0)
			rb_sys_fail("mq_getattr");
	}

	rb_scan_args(argc, argv, "02", &buffer, &timeout);
	x.timeout = convert_timeout(&expire, timeout);

	if (NIL_P(buffer)) {
		buffer = rb_str_new(0, mq->attr.mq_msgsize);
	} else {
		StringValue(buffer);
		rb_str_modify(buffer);
		rb_str_resize(buffer, mq->attr.mq_msgsize);
	}
	OBJ_TAINT(buffer);
	x.msg_ptr = RSTRING_PTR(buffer);
	x.msg_len = (size_t)mq->attr.mq_msgsize;
	x.des = mq->des;

	if (mq->attr.mq_flags & O_NONBLOCK) {
		r = (ssize_t)xrecv(&x);
	} else {
		r = (ssize_t)rb_thread_blocking_region(xrecv, &x,
		                                       RUBY_UBF_IO, 0);
	}
	if (r < 0)
		rb_sys_fail("mq_receive");

	rb_str_set_len(buffer, r);

	if (wantarray)
		return rb_ary_new3(2, buffer, UINT2NUM(x.msg_prio));
	return buffer;
}

/*
 * call-seq:
 *	mq.attr	=>	 mq_attr
 *
 * Returns a POSIX_MQ::Attr struct containing the attributes
 * of the message queue.  See the mq_getattr(3) manpage for
 * more details.
 */
static VALUE getattr(VALUE self)
{
	struct posix_mq *mq = get(self, 1);
	VALUE astruct;

	if (mq_getattr(mq->des, &mq->attr) < 0)
		rb_sys_fail("mq_getattr");

	return rb_funcall(cAttr, id_new, 4,
	                  LONG2NUM(mq->attr.mq_flags),
	                  LONG2NUM(mq->attr.mq_maxmsg),
	                  LONG2NUM(mq->attr.mq_msgsize),
	                  LONG2NUM(mq->attr.mq_curmsgs));
}

/*
 * call-seq:
 *	mq.attr = POSIX_MQ::Attr(IO::NONBLOCK)		=> mq_attr
 *
 * Only the IO::NONBLOCK flag may be set or unset (zero) in this manner.
 * See the mq_setattr(3) manpage for more details.
 *
 * Consider using the POSIX_MQ#nonblock= method as it is easier and
 * more natural to use.
 */
static VALUE setattr(VALUE self, VALUE astruct)
{
	struct posix_mq *mq = get(self, 1);
	struct mq_attr newattr;

	rstruct2mqattr(&newattr, astruct, 0);

	if (mq_setattr(mq->des, &newattr, NULL) < 0)
		rb_sys_fail("mq_setattr");

	return astruct;
}

/*
 * call-seq:
 *	mq.close	=> nil
 *
 * Closes the underlying message queue descriptor.
 * If this descriptor had a registered notification request, the request
 * will be removed so another descriptor or process may register a
 * notification request.  Message queue descriptors are automatically
 * closed by garbage collection.
 */
static VALUE _close(VALUE self)
{
	struct posix_mq *mq = get(self, 1);

	if (! MQ_IO_CLOSE(mq)) {
		if (mq_close(mq->des) == -1)
			rb_sys_fail("mq_close");
	}
	mq->des = MQD_INVALID;

	return Qnil;
}

/*
 *  call-seq:
 *	mq.closed?	=> true or false
 *
 *  Returns +true+ if the message queue descriptor is closed and therefore
 *  unusable, otherwise +false+
 */
static VALUE closed(VALUE self)
{
	struct posix_mq *mq = get(self, 0);

	return mq->des == MQD_INVALID ? Qtrue : Qfalse;
}

/*
 * call-seq:
 *	mq.name		=> string
 *
 * Returns the string name of message queue associated with +mq+
 */
static VALUE name(VALUE self)
{
	struct posix_mq *mq = get(self, 0);

	return rb_str_dup(mq->name);
}

static int lookup_sig(VALUE sig)
{
	static VALUE list;
	const char *ptr;
	long len;

	sig = rb_obj_as_string(sig);
	len = RSTRING_LEN(sig);
	ptr = RSTRING_PTR(sig);

	if (len > 3 && !memcmp("SIG", ptr, 3))
		sig = rb_str_new(ptr + 3, len - 3);

	if (!list) {
		VALUE mSignal = rb_const_get(rb_cObject, rb_intern("Signal"));

		list = rb_funcall(mSignal, rb_intern("list"), 0, 0);
		rb_global_variable(&list);
	}

	sig = rb_hash_aref(list, sig);
	if (NIL_P(sig))
		rb_raise(rb_eArgError, "invalid signal: %s\n", ptr);

	return NUM2INT(sig);
}

/*
 * TODO: Under Linux, we could just use netlink directly
 * the same way glibc does...
 */
/* we spawn a thread just to write ONE byte into an fd (usually a pipe) */
static void thread_notify_fd(union sigval sv)
{
	int fd = sv.sival_int;

	while ((write(fd, "", 1) < 0) && (errno == EINTR || errno == EAGAIN));
}

static void my_mq_notify(mqd_t des, struct sigevent *not)
{
	mqd_t rv = mq_notify(des, not);

	if (rv == MQD_INVALID) {
		if (errno == ENOMEM) {
			rb_gc();
			rv = mq_notify(des, not);
		}
		if (rv == MQD_INVALID)
			rb_sys_fail("mq_notify");
	}
}

/* :nodoc: */
static VALUE setnotify_exec(VALUE self, VALUE io, VALUE thr)
{
	int fd = NUM2INT(rb_funcall(io, id_fileno, 0, 0));
	struct posix_mq *mq = get(self, 1);
	struct sigevent not;
	pthread_attr_t attr;

	errno = pthread_attr_init(&attr);
	if (errno) rb_sys_fail("pthread_attr_init");

	errno = pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
	if (errno) rb_sys_fail("pthread_attr_setdetachstate");

#ifdef PTHREAD_STACK_MIN
	(void)pthread_attr_setstacksize(&attr, PTHREAD_STACK_MIN);
#endif

	not.sigev_notify = SIGEV_THREAD;
	not.sigev_notify_function = thread_notify_fd;
	not.sigev_notify_attributes = &attr;
	not.sigev_value.sival_int = fd;

	if (!NIL_P(mq->thread))
		rb_funcall(mq->thread, id_kill, 0, 0);
	mq->thread = thr;

	my_mq_notify(mq->des, &not);

	return thr;
}

/* :nodoc: */
static VALUE notify_cleanup(VALUE self)
{
	struct posix_mq *mq = get(self, 1);

	if (!NIL_P(mq->thread)) {
		rb_funcall(mq->thread, id_kill, 0, 0);
		mq->thread = Qnil;
	}
	return Qnil;
}

/*
 * call-seq:
 *	mq.notify = signal	=> signal
 *
 * Registers the notification request to deliver a given +signal+
 * to the current process when message is received.
 * If +signal+ is +nil+, it will unregister and disable the notification
 * request to allow other processes to register a request.
 * If +signal+ is +false+, it will register a no-op notification request
 * which will prevent other processes from registering a notification.
 * If +signal+ is an +IO+ object, it will spawn a thread upon the
 * arrival of the next message and write one "\\0" byte to the file
 * descriptor belonging to that IO object.
 * Only one process may have a notification request for a queue
 * at a time, Errno::EBUSY will be raised if there is already
 * a notification request registration for the queue.
 *
 * Notifications are only fired once and processes must reregister
 * for subsequent notifications.
 *
 * For readers of the mq_notify(3) manpage, passing +false+
 * is equivalent to SIGEV_NONE, and passing +nil+ is equivalent
 * of passing a NULL notification pointer to mq_notify(3).
 */
static VALUE setnotify(VALUE self, VALUE arg)
{
	struct posix_mq *mq = get(self, 1);
	struct sigevent not;
	struct sigevent * notification = &not;
	VALUE rv = arg;

	notify_cleanup(self);
	not.sigev_notify = SIGEV_SIGNAL;

	switch (TYPE(arg)) {
	case T_FALSE:
		not.sigev_notify = SIGEV_NONE;
		break;
	case T_NIL:
		notification = NULL;
		break;
	case T_FIXNUM:
		not.sigev_signo = NUM2INT(arg);
		break;
	case T_SYMBOL:
	case T_STRING:
		not.sigev_signo = lookup_sig(arg);
		rv = INT2NUM(not.sigev_signo);
		break;
	default:
		rb_raise(rb_eArgError, "must be a signal or nil");
	}

	my_mq_notify(mq->des, notification);

	return rv;
}

/*
 * call-seq:
 *	mq.nonblock?	=> true or false
 *
 * Returns the current non-blocking state of the message queue descriptor.
 */
static VALUE getnonblock(VALUE self)
{
	struct posix_mq *mq = get(self, 1);

	return mq->attr.mq_flags & O_NONBLOCK ? Qtrue : Qfalse;
}

/*
 * call-seq:
 *	mq.nonblock = boolean	=> boolean
 *
 * Enables or disables non-blocking operation for the message queue
 * descriptor.  Errno::EAGAIN will be raised in situations where
 * the queue would block.  This is not compatible with +timeout+
 * arguments to POSIX_MQ#send and POSIX_MQ#receive.
 */
static VALUE setnonblock(VALUE self, VALUE nb)
{
	struct mq_attr newattr;
	struct posix_mq *mq = get(self, 1);

	if (nb == Qtrue)
		newattr.mq_flags = O_NONBLOCK;
	else if (nb == Qfalse)
		newattr.mq_flags = 0;
	else
		rb_raise(rb_eArgError, "must be true or false");

	if (mq_setattr(mq->des, &newattr, &mq->attr) < 0)
		rb_sys_fail("mq_setattr");

	mq->attr.mq_flags = newattr.mq_flags;

	return nb;
}

void Init_posix_mq_ext(void)
{
	cPOSIX_MQ = rb_define_class("POSIX_MQ", rb_cObject);
	rb_define_alloc_func(cPOSIX_MQ, alloc);
	cAttr = rb_const_get(cPOSIX_MQ, rb_intern("Attr"));

	/*
	 * The maximum number of open message descriptors supported
	 * by the system.  This may be -1, in which case it is dynamically
	 * set at runtime.  Consult your operating system documentation
	 * for system-specific information about this.
	 */
	rb_define_const(cPOSIX_MQ, "OPEN_MAX",
	                LONG2NUM(sysconf(_SC_MQ_OPEN_MAX)));

	/*
	 * The maximum priority that may be specified for POSIX_MQ#send
	 * On POSIX-compliant systems, this is at least 31, but some
	 * systems allow higher limits.
	 * The minimum priority is always zero.
	 */
	rb_define_const(cPOSIX_MQ, "PRIO_MAX",
	                LONG2NUM(sysconf(_SC_MQ_PRIO_MAX)));

	rb_define_singleton_method(cPOSIX_MQ, "unlink", s_unlink, 1);

	rb_define_method(cPOSIX_MQ, "initialize", init, -1);
	rb_define_method(cPOSIX_MQ, "send", _send, -1);
	rb_define_method(cPOSIX_MQ, "<<", send0, 1);
	rb_define_method(cPOSIX_MQ, "receive", receive, -1);
	rb_define_method(cPOSIX_MQ, "shift", shift, -1);
	rb_define_method(cPOSIX_MQ, "attr", getattr, 0);
	rb_define_method(cPOSIX_MQ, "attr=", setattr, 1);
	rb_define_method(cPOSIX_MQ, "close", _close, 0);
	rb_define_method(cPOSIX_MQ, "closed?", closed, 0);
	rb_define_method(cPOSIX_MQ, "unlink", _unlink, 0);
	rb_define_method(cPOSIX_MQ, "name", name, 0);
	rb_define_method(cPOSIX_MQ, "notify=", setnotify, 1);
	rb_define_method(cPOSIX_MQ, "nonblock=", setnonblock, 1);
	rb_define_method(cPOSIX_MQ, "notify_exec", setnotify_exec, 2);
	rb_define_method(cPOSIX_MQ, "notify_cleanup", notify_cleanup, 0);
	rb_define_method(cPOSIX_MQ, "nonblock?", getnonblock, 0);
#ifdef MQD_TO_FD
	rb_define_method(cPOSIX_MQ, "to_io", to_io, 0);
#endif

	id_new = rb_intern("new");
	id_kill = rb_intern("kill");
	id_fileno = rb_intern("fileno");
	id_mul = rb_intern("*");
	id_divmod = rb_intern("divmod");
	id_flags = rb_intern("flags");
	id_maxmsg = rb_intern("maxmsg");
	id_msgsize = rb_intern("msgsize");
	id_curmsgs = rb_intern("curmsgs");
	sym_r = ID2SYM(rb_intern("r"));
	sym_w = ID2SYM(rb_intern("w"));
	sym_rw = ID2SYM(rb_intern("rw"));
}
