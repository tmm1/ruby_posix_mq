# -*- encoding: binary -*-
#
# This class represents an POSIX message queue descriptor (mqd_t)
# object.  It matches the C API for POSIX messages queues closely.
#
# See the link:README for examples on how to use it.
class POSIX_MQ

  # An analogous Struct to "struct mq_attr" in C.
  # This may be used in arguments for POSIX_MQ.new and
  # POSIX_MQ#attr=.  POSIX_MQ#attr returns an instance
  # of this class.
  #
  # See the mq_getattr(3) manpage for more information on the values.
  Attr = Struct.new(:flags, :maxmsg, :msgsize, :curmsgs)

  # Opens a POSIX message queue and performs operations on the
  # given block, closing the message queue at exit.
  # All all arguments are passed to POSIX_MQ.new.
  def self.open(*args)
    mq = new(*args)
    block_given? or return mq
    begin
      yield mq
    ensure
      mq.close unless mq.closed?
    end
  end

  # Executes the given block upon reception of the next message in an
  # empty queue.  If the message queue is not empty, then this block
  # will only be fired after the queue is emptied and repopulated with
  # one message.
  #
  # This block will only be executed upon the arrival of the
  # first message and must be reset/reenabled for subsequent
  # notifications.  This block will execute in a separate Ruby
  # Thread (and thus will safely have the GVL by default).
  #
  # This method is only supported on platforms that implement
  # SIGEV_THREAD functionality in mq_notify(3).  So far we only
  # know of glibc + Linux supporting this.  Please let us
  # know if your platform can support this functionality and
  # are willing to test for us <ruby-posix-mq@bogomips.org>
  #
  # As far as we can tell, this method is not very useful
  # nor efficient.  You would be better served using signals or
  # just blocking.  On Linux and FreeBSD, you can use POSIX_MQ
  # with I/O multiplexing (IO.select, EventMachine), too.
  def notify(&block)
    block.arity == 1 or
      raise ArgumentError, "arity of notify block must be 1"
    r, w = IO.pipe
    notify_exec(w, Thread.new(block) do |blk|
      begin
        begin
          r.read(1) or raise Errno::EINTR
        rescue Errno::EINTR, Errno::EAGAIN
          retry
        end
        blk.call(self)
      ensure
        notify_cleanup
        r.close rescue nil
        w.close rescue nil
      end
    end)
    nil
  end if RUBY_PLATFORM =~ /linux/

  # There's no point in ever duping a POSIX_MQ object.
  # All send/receive operations are atomic and only one
  # native thread may be notified at a time
  def dup
    self
  end

  # There's no point in ever cloning a POSIX_MQ object.
  # All send/receive operations are atomic and only one
  # native thread may be notified at a time
  alias clone dup

end

require 'posix_mq_ext'
