# -*- encoding: binary -*-
ENV["VERSION"] or abort "VERSION= must be specified"
manifest = File.readlines('.manifest').map! { |x| x.chomp! }
require 'olddoc'
extend Olddoc::Gemspec
name, summary, title = readme_metadata

Gem::Specification.new do |s|
  s.name = %q{posix_mq}
  s.version = ENV["VERSION"].dup
  s.authors = ["Ruby POSIX MQ hackers"]
  s.description = readme_description
  s.email = %q{ruby-posix-mq@bogomips.org}
  s.executables = %w(posix-mq-rb)
  s.extensions = %w(ext/posix_mq/extconf.rb)
  s.extra_rdoc_files = extra_rdoc_files(manifest)
  s.files = manifest
  s.homepage = Olddoc.config['rdoc_url']
  s.summary = summary
  s.test_files = manifest.grep(%r{\Atest/test_.*\.rb\z})
  s.add_development_dependency(%q<olddoc>, "~> 1.0")
  s.licenses = %w(GPL-2.0 LGPL-3.0+)
end
