# -*- encoding: binary -*-

ENV["VERSION"] or abort "VERSION= must be specified"
manifest = File.readlines('.manifest').map! { |x| x.chomp! }
test_files = manifest.grep(%r{\Atest/test_.*\.rb\z})

Gem::Specification.new do |s|
  s.name = %q{posix_mq}
  s.version = ENV["VERSION"]

  s.authors = ["Ruby POSIX MQ hackers"]
  s.date = Time.now.utc.strftime('%Y-%m-%d')
  s.description = File.read("README").split(/\n\n/)[1]
  s.email = %q{ruby.posix.mq@librelist.com}
  s.executables = %w(posix-mq-rb)
  s.extensions = %w(ext/posix_mq/extconf.rb)

  s.extra_rdoc_files = File.readlines('.document').map! do |x|
    x.chomp!
    if File.directory?(x)
      manifest.grep(%r{\A#{x}/})
    elsif File.file?(x)
      x
    else
      nil
    end
  end.flatten.compact

  s.files = manifest
  s.homepage = %q{http://bogomips.org/ruby_posix_mq/}
  s.summary = %q{POSIX Message Queues for Ruby}
  s.rdoc_options = [ "-Na", "-t", "posix_mq - #{s.summary}" ]
  s.require_paths = %w(lib)
  s.rubyforge_project = %q{qrp}

  s.test_files = test_files

  # s.licenses = %w(LGPLv3) # accessor not compatible with older RubyGems
end
