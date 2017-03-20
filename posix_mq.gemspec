# -*- encoding: binary -*-
ENV["VERSION"] ||= '2.4.0'
if File.exist?('.manifest')
  manifest = IO.readlines('.manifest').map!(&:chomp!)
else
  manifest = `git ls-files`.split("\n")
end

Gem::Specification.new do |s|
  s.name = %q{posix_mq}
  s.version = ENV["VERSION"].dup
  s.authors = ["Ruby POSIX MQ hackers"]
  s.description = File.read('README').split("\n\n")[1]
  s.email = %q{ruby-posix-mq@bogomips.org}
  s.executables = %w(posix-mq-rb)
  s.extensions = %w(ext/posix_mq/extconf.rb)
  s.extra_rdoc_files = IO.readlines('.document').map!(&:chomp!).keep_if do |f|
    File.exist?(f)
  end
  s.files = manifest
  s.homepage = 'https://bogomips.org/ruby_posix_mq/'
  s.summary = 'POSIX message queues for Ruby'
  s.test_files = manifest.grep(%r{\Atest/test_.*\.rb\z})
  s.licenses = %w(GPL-2.0 LGPL-3.0+)
end
