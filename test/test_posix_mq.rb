# -*- encoding: binary -*-
require 'test/unit'
require 'thread'
require 'fcntl'
$stderr.sync = $stdout.sync = true
$-w = true
require 'posix_mq'

class Test_POSIX_MQ < Test::Unit::TestCase

  POSIX_MQ.method_defined?(:to_io) or
    warn "POSIX_MQ#to_io not supported on this platform: #{RUBY_PLATFORM}"
  POSIX_MQ.method_defined?(:notify) or
    warn "POSIX_MQ#notify not supported on this platform: #{RUBY_PLATFORM}"
  POSIX_MQ.respond_to?(:for_fd) or
    warn "POSIX_MQ::for_fd not supported on this platform: #{RUBY_PLATFORM}"

  def setup
    @mq = nil
    @path = "/posix_mq.rb.#{Time.now.to_i}.#$$.#{rand}"
  end

  def teardown
    @mq or return
    assert_equal @mq, @mq.unlink
    assert ! @mq.closed?
    assert_nil @mq.close
    assert @mq.closed?
  end

  def test_open_with_null_byte
    assert_raises(ArgumentError) { POSIX_MQ.open("/hello\0world", :rw) }
  end

  def test_unlink_with_null_byte
    assert_raises(ArgumentError) { POSIX_MQ.open("/hello\0world", :rw) }
  end

  def test_gc
    assert_nothing_raised do
      2025.times { POSIX_MQ.new(@path, :rw) }
      2025.times {
        @mq = POSIX_MQ.new(@path, :rw)
        @mq.to_io if @mq.respond_to?(:to_io)
      }
    end
  end unless defined?RUBY_ENGINE && RUBY_ENGINE == "rbx"

  def test_name_clobber_proof
    @mq = POSIX_MQ.new(@path, :rw)
    tmp = @mq.name
    tmp.freeze
    assert_nothing_raised { @mq.name.gsub!(/\A/, "foo") }
    assert_equal tmp, @mq.name
    assert tmp.object_id != @mq.name.object_id
  end

  def test_dup_clone
    @mq = POSIX_MQ.new(@path, :rw)
    dup = @mq.dup
    assert_equal @mq.object_id, dup.object_id
    clone = @mq.clone
    assert_equal @mq.object_id, clone.object_id
  end

  def test_timed_receive_float
    interval = 0.01
    @mq = POSIX_MQ.new(@path, :rw)
    assert ! @mq.nonblock?
    t0 = Time.now
    maybe_timeout { @mq.receive "", interval } or return
    elapsed = Time.now - t0
    assert_operator elapsed, :>, interval, elapsed.inspect
    assert_operator elapsed, :<, 0.04, elapsed.inspect
  end

  def test_timed_receive_divmod
    interval = Object.new
    def interval.divmod(num)
      num == 1 ? [ 0, 0.01 ] : nil
    end
    @mq = POSIX_MQ.new(@path, :rw)
    assert ! @mq.nonblock?
    t0 = Time.now
    maybe_timeout { @mq.receive "", interval } or return
    elapsed = Time.now - t0
    assert_operator elapsed, :>=, 0.01, elapsed.inspect
    assert_operator elapsed, :<=, 0.04, elapsed.inspect
  end

  def test_timed_receive_fixnum
    interval = 1
    @mq = POSIX_MQ.new(@path, :rw)
    assert ! @mq.nonblock?
    t0 = Time.now
    maybe_timeout { @mq.receive "", interval } or return
    elapsed = Time.now - t0
    assert elapsed >= interval, elapsed.inspect
    assert elapsed < 1.10, elapsed.inspect
  end

  def test_signal_safe
    alarm = lambda do |x|
      Thread.new(x) do |time|
        sleep(time)
        Process.kill(:USR1, $$)
      end
    end
    alarms = 0
    sig = trap(:USR1) do
      alarms += 1
      Thread.new { @mq.send("HI") }
    end
    interval = 1
    alarm.call interval
    @mq = POSIX_MQ.new(@path, :rw)
    assert ! @mq.nonblock?
    t0 = Time.now
    a = @mq.receive
    elapsed = Time.now - t0
    assert_equal(["HI", 0], a)
    assert elapsed >= interval, elapsed.inspect
    assert elapsed < 1.10, elapsed.inspect
    assert_equal 1, alarms
  ensure
    trap(:USR1, sig) if sig
  end

  def test_timed_send
    interval = 0.01
    @mq = POSIX_MQ.new(@path, :rw, 0666, POSIX_MQ::Attr[0, 1, 1, 0])
    assert ! @mq.nonblock?
    assert_nothing_raised {
      begin
        @mq.send "A", 1, interval
      rescue NotImplementedError
        return
      end
    }
    t0 = Time.now
    maybe_timeout { @mq.send "B", 1, interval } or return
    elapsed = Time.now - t0
    assert elapsed > interval
  end

  def test_open
    POSIX_MQ.open(@path, IO::CREAT|IO::WRONLY, 0666) do |mq|
      @mq = mq
      assert mq.kind_of?(POSIX_MQ)
      assert_equal @path, mq.name
      assert_equal true, mq.send("HI", 0)
      assert_equal 1, mq.attr.curmsgs
      assert_nil mq.close
      assert_raises(IOError) { mq.close }
    end
    assert @mq.closed?
    @mq = nil
    POSIX_MQ.unlink(@path)
  end

  def test_name
    path = "" << @path.dup
    path.freeze
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::WRONLY, 0666
    assert_equal path, @mq.name
  end

  def test_new_readonly
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::WRONLY, 0666
    rd = POSIX_MQ.new @path, IO::RDONLY
    assert_equal @mq.name, rd.name
    assert_nil rd.close
  end

  def test_send0_receive
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::RDWR, 0666
    assert_equal(@mq, @mq << "hello")
    assert_equal [ "hello", 0 ], @mq.receive
  end

  def test_send0_chain
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::RDWR, 0666
    @mq << "hello" << "world"
    assert_equal [ "hello", 0 ], @mq.receive
    assert_equal [ "world", 0 ], @mq.receive
  end

  def test_shift
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::RDWR, 0666
    @mq << "hello"
    assert_equal "hello", @mq.shift
  end

  def test_shift_buf
    buf = ""
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::RDWR, 0666
    @mq << "hello"
    assert_equal "hello", @mq.shift(buf)
    assert_equal "hello", buf
  end

  def test_send_receive
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::RDWR, 0666
    assert_equal true, @mq.send("hello", 0)
    assert_equal [ "hello", 0 ], @mq.receive
  end

  def test_send_receive_buf
    buf = ""
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::RDWR, 0666
    assert_equal true, @mq.send("hello", 0)
    assert_equal [ "hello", 0 ], @mq.receive(buf)
    assert_equal "hello", buf
  end

  def test_send_receive_prio
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::RDWR, 0666
    assert_equal true, @mq.send("hello", 2)
    assert_equal [ "hello", 2 ], @mq.receive
  end

  def test_getattr
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::WRONLY, 0666
    mq_attr = @mq.attr
    assert_equal POSIX_MQ::Attr, mq_attr.class
    assert mq_attr.flags.kind_of?(Integer)
    assert mq_attr.maxmsg.kind_of?(Integer)
    assert mq_attr.msgsize.kind_of?(Integer)
    assert mq_attr.curmsgs.kind_of?(Integer)
  end

  def test_to_io
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::RDWR, 0666
    assert @mq.to_io.kind_of?(IO)
    assert_nothing_raised { IO.select([@mq], nil, nil, 0) }
  end if POSIX_MQ.method_defined?(:to_io)

  def test_for_fd
    buf = ""
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::RDWR, 0666
    @alt = POSIX_MQ.for_fd(@mq.to_io.to_i)
    assert_equal true, @mq.send("hello", 0)
    assert_equal [ "hello", 0 ], @alt.receive(buf)
    assert_equal "hello", buf
    assert_equal @mq.to_io.to_i, @alt.to_io.to_i
    assert_raises(ArgumentError) { @alt.name }
    assert_raises(Errno::EBADF) { POSIX_MQ.for_fd(1) }
    @alt.autoclose = false
    assert_equal false, @alt.autoclose?

    # iterate a bunch and hope GC kicks in
    fd = @mq.to_io.fileno
    10_000.times do
      mq = POSIX_MQ.for_fd(fd)
      assert_equal true, mq.autoclose?
      mq.autoclose = false
      assert_equal false, mq.autoclose?
    end
  end if POSIX_MQ.respond_to?(:for_fd) && POSIX_MQ.method_defined?(:to_io)

  def test_autoclose_propagates_to_io
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::RDWR, 0666
    @mq.autoclose = false
    assert_equal false, @mq.to_io.autoclose?
    @mq.autoclose = true
    assert_equal true, @mq.to_io.autoclose?
  end if POSIX_MQ.method_defined?(:to_io)

  def test_notify
    rd, wr = IO.pipe
    orig = trap(:USR1) { wr.syswrite('.') }
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::RDWR, 0666
    assert_nothing_raised { @mq.notify = :SIGUSR1 }
    assert_nothing_raised { @mq.send("hello", 0) }
    assert_equal [[rd], [], []], IO.select([rd], nil, nil, 10)
    assert_equal '.', rd.sysread(1)
    assert_nil(@mq.notify = nil)
    assert_nothing_raised { @mq.send("hello", 0) }
    assert_nil IO.select([rd], nil, nil, 0.1)
    ensure
      trap(:USR1, orig)
  end if POSIX_MQ.method_defined?(:to_io)

  def test_notify_none
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::RDWR, 0666
    assert_nothing_raised { @mq.notify = false }
    pid = fork do
      begin
        @mq.notify = :USR1
      rescue Errno::EBUSY
        exit 0
      rescue => e
        p e
      end
      exit! 1
    end
    _, status = Process.waitpid2(pid)
    assert status.success?, status.inspect
  end

  def test_setattr
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::WRONLY, 0666
    mq_attr = POSIX_MQ::Attr.new(IO::NONBLOCK)
    @mq.attr = mq_attr
    assert_equal IO::NONBLOCK, @mq.attr.flags
    assert mq_attr.flags.kind_of?(Integer)

    mq_attr.flags = 0
    @mq.attr = mq_attr
    assert_equal 0, @mq.attr.flags
  end

  def test_setattr_fork
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::WRONLY, 0666
    mq_attr = POSIX_MQ::Attr.new(IO::NONBLOCK)
    @mq.attr = mq_attr
    assert @mq.nonblock?

    pid = fork { @mq.nonblock = false }
    assert Process.waitpid2(pid)[1].success?
    assert ! @mq.nonblock?
  end

  def test_new_nonblocking
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::WRONLY|IO::NONBLOCK, 0666
    assert @mq.nonblock?
  end

  def test_new_blocking
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::WRONLY, 0666
    assert ! @mq.nonblock?
  end

  def test_nonblock_toggle
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::WRONLY, 0666
    assert ! @mq.nonblock?
    @mq.nonblock = true
    assert @mq.nonblock?
    @mq.nonblock = false
    assert ! @mq.nonblock?
    assert_raises(ArgumentError) { @mq.nonblock = nil }
  end

  def test_new_sym_w
    @mq = POSIX_MQ.new @path, :w
    assert_equal IO::WRONLY, @mq.to_io.fcntl(Fcntl::F_GETFL)
  end if POSIX_MQ.method_defined?(:to_io)

  def test_new_sym_r
    @mq = POSIX_MQ.new @path, :w
    mq = nil
    assert_nothing_raised { mq = POSIX_MQ.new @path, :r }
    assert_equal IO::RDONLY, mq.to_io.fcntl(Fcntl::F_GETFL)
    assert_nil mq.close
  end if POSIX_MQ.method_defined?(:to_io)

  def test_new_path_only
    @mq = POSIX_MQ.new @path, :w
    mq = nil
    assert_nothing_raised { mq = POSIX_MQ.new @path }
    assert_equal IO::RDONLY, mq.to_io.fcntl(Fcntl::F_GETFL)
    assert_nil mq.close
  end if POSIX_MQ.method_defined?(:to_io)

  def test_new_sym_wr
    @mq = POSIX_MQ.new @path, :rw
    assert_equal IO::RDWR, @mq.to_io.fcntl(Fcntl::F_GETFL)
  end if POSIX_MQ.method_defined?(:to_io)

  def test_new_attr
    mq_attr = POSIX_MQ::Attr.new(IO::NONBLOCK, 1, 1, 0)
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::RDWR, 0666, mq_attr
    assert @mq.nonblock?
    assert_equal mq_attr, @mq.attr

    assert_raises(Errno::EAGAIN) { @mq.receive }
    assert_raises(Errno::EMSGSIZE) { @mq << '..' }
    assert_nothing_raised { @mq << '.' }
    assert_equal [ '.', 0 ], @mq.receive
    assert_nothing_raised { @mq << '.' }
    assert_raises(Errno::EAGAIN) { @mq << '.' }
  end

  def test_try
    mq_attr = POSIX_MQ::Attr.new(IO::NONBLOCK, 1, 1, 0)
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::RDWR, 0666, mq_attr

    assert_nil @mq.tryreceive
    assert_nil @mq.tryshift
    assert_equal true, @mq.trysend("a")
    assert_equal [ "a", 0 ], @mq.tryreceive
    assert_equal true, @mq.trysend("b")
    assert_equal "b", @mq.tryshift
    assert_equal true, @mq.trysend("c")
    assert_equal false, @mq.trysend("d")
  end

  def test_prio_max
    min_posix_mq_prio_max = 31 # defined by POSIX
    assert POSIX_MQ::PRIO_MAX >= min_posix_mq_prio_max
  end

  def test_open_max
    assert POSIX_MQ::OPEN_MAX.kind_of?(Integer)
  end

  def test_notify_block_replace
    q = Queue.new
    @mq = POSIX_MQ.new(@path, :rw)
    assert_nothing_raised { @mq.notify { |mq| q << mq } }
    assert_nothing_raised { Process.waitpid2(fork { @mq << "hi" }) }
    assert_equal @mq.object_id, q.pop.object_id
    assert_equal "hi", @mq.receive.first
    assert_nothing_raised { @mq.notify { |mq| q << "hi" } }
    assert_nothing_raised { Process.waitpid2(fork { @mq << "bye" }) }
    assert_equal "hi", q.pop
  end if POSIX_MQ.method_defined?(:notify)

  def test_notify_thread
    q = Queue.new
    @mq = POSIX_MQ.new(@path, :rw)
    @mq.notify { |mq| q << Thread.current }
    @mq << "."
    x = q.pop
    assert x.instance_of?(Thread)
    assert Thread.current != x
  end if POSIX_MQ.method_defined?(:notify)

  def test_bad_open_mode
    assert_raises(ArgumentError) { POSIX_MQ.new(@path, "rw") }
  end

  def test_bad_open_attr
    assert_raises(TypeError) { POSIX_MQ.new(@path, :rw, 0666, [0, 1, 1, 0]) }
  end

  def test_bad_setattr
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::WRONLY, 0666
    assert_raises(TypeError) { @mq.attr = {} }
    assert_raises(TypeError) { @mq.attr = Struct.new(:a,:b,:c,:d).new }
  end

  def maybe_timeout
    yield
    assert_raises(exc) { } # FAIL
    return true
    rescue Errno::ETIMEDOUT => e
      return true
    rescue NotImplementedError => e
      warn "E: #{e}"
      return false
  end
end
