# -*- encoding: binary -*-
class POSIX_MQ

  # version of POSIX_MQ, currently 0.1.0
  VERSION = '0.1.0'

  # An analogous Struct to "struct mq_attr" in C.
  # This may be used in arguments for POSIX_MQ.new and
  # POSIX_MQ#attr=.  POSIX_MQ#attr returns an instance
  # of this class.
  #
  # See the mq_getattr(3) manpage for more information on the values.
  Attr = Struct.new(:flags, :maxmsg, :msgsize, :curmsgs)

  class << self

    # Opens a POSIX message queue and performs operations on the
    # given block, closing the message queue at exit.
    # All all arguments are passed to POSIX_MQ.new.
    def open(*args)
      mq = new(*args)
      block_given? or return mq
      begin
        yield mq
      ensure
        mq.close unless mq.closed?
      end
    end

  end

end

require 'posix_mq_ext'
