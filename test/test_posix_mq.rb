# -*- encoding: binary -*-
require 'test/unit'
require 'posix_mq'
require 'thread'
require 'fcntl'
$stderr.sync = $stdout.sync = true

class Test_POSIX_MQ < Test::Unit::TestCase

  HAVE_TO_IO = if POSIX_MQ.instance_methods.grep(/\Ato_io\z/).empty?
    warn "POSIX_MQ#to_io not supported on this platform: #{RUBY_PLATFORM}"
    false
  else
    true
  end

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

  def test_timed_receive
    interval = 0.01
    @mq = POSIX_MQ.new(@path, :rw)
    assert ! @mq.nonblock?
    t0 = Time.now
    assert_raises(Errno::ETIMEDOUT) { @mq.receive "", interval }
    elapsed = Time.now - t0
    assert elapsed > interval
  end

  def test_timed_send
    interval = 0.01
    @mq = POSIX_MQ.new(@path, :rw, 0666, POSIX_MQ::Attr[0, 1, 1, 0])
    assert ! @mq.nonblock?
    assert_nothing_raised { @mq.send "A", 1, interval }
    t0 = Time.now
    assert_raises(Errno::ETIMEDOUT) { @mq.send "B", 1, interval }
    elapsed = Time.now - t0
    assert elapsed > interval
  end

  def test_open
    POSIX_MQ.open(@path, IO::CREAT|IO::WRONLY, 0666) do |mq|
      @mq = mq
      assert mq.kind_of?(POSIX_MQ)
      assert_equal @path, mq.name
      assert_nil mq.send("HI", 0)
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

  def test_send_receive
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::RDWR, 0666
    assert_nil @mq.send("hello", 0)
    assert_equal [ "hello", 0 ], @mq.receive
  end

  def test_send_receive_buf
    buf = ""
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::RDWR, 0666
    assert_nil @mq.send("hello", 0)
    assert_equal [ "hello", 0 ], @mq.receive(buf)
    assert_equal "hello", buf
  end

  def test_send_receive_prio
    @mq = POSIX_MQ.new @path, IO::CREAT|IO::RDWR, 0666
    assert_nil @mq.send("hello", 2)
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
  end if HAVE_TO_IO

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
  end

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
  end if HAVE_TO_IO

  def test_new_sym_r
    @mq = POSIX_MQ.new @path, :w
    mq = nil
    assert_nothing_raised { mq = POSIX_MQ.new @path, :r }
    assert_equal IO::RDONLY, mq.to_io.fcntl(Fcntl::F_GETFL)
    assert_nil mq.close
  end if HAVE_TO_IO

  def test_new_path_only
    @mq = POSIX_MQ.new @path, :w
    mq = nil
    assert_nothing_raised { mq = POSIX_MQ.new @path }
    assert_equal IO::RDONLY, mq.to_io.fcntl(Fcntl::F_GETFL)
    assert_nil mq.close
  end if HAVE_TO_IO

  def test_new_sym_wr
    @mq = POSIX_MQ.new @path, :rw
    assert_equal IO::RDWR, @mq.to_io.fcntl(Fcntl::F_GETFL)
  end if HAVE_TO_IO

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
    @mq << "hi"
    assert_equal POSIX_MQ, q.pop.class
    assert_equal "hi", @mq.receive.first
    assert_nothing_raised { @mq.notify { |mq| q << "hi" } }
    @mq << "bye"
    assert_equal "hi", q.pop
  end

  def test_notify_thread
    q = Queue.new
    @mq = POSIX_MQ.new(@path, :rw)
    @mq.notify_thread = thr = Thread.new { sleep }
    assert thr.alive?
    @mq.notify { |mq| q << Thread.current }
    @mq << "."
    x = q.pop
    assert x.instance_of?(Thread)
    assert Thread.current != x
    assert ! thr.alive?
  end
end
