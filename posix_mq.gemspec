# -*- encoding: binary -*-
ENV["VERSION"] or abort "VERSION= must be specified"
manifest = File.readlines('.manifest').map! { |x| x.chomp! }
require 'wrongdoc'
extend Wrongdoc::Gemspec
name, summary, title = readme_metadata

Gem::Specification.new do |s|
  s.name = %q{posix_mq}
  s.version = ENV["VERSION"].dup
  s.authors = ["Ruby POSIX MQ hackers"]
  s.date = Time.now.utc.strftime('%Y-%m-%d')
  s.description = readme_description
  s.email = %q{ruby.posix.mq@librelist.com}
  s.executables = %w(posix-mq-rb)
  s.extensions = %w(ext/posix_mq/extconf.rb)
  s.extra_rdoc_files = extra_rdoc_files(manifest)
  s.files = manifest
  s.homepage = Wrongdoc.config[:rdoc_url]
  s.summary = summary
  s.rdoc_options = rdoc_options
  s.require_paths = %w(lib)
  s.rubyforge_project = %q{qrp}
  s.test_files = manifest.grep(%r{\Atest/test_.*\.rb\z})
  s.add_development_dependency(%q<wrongdoc>, "~> 1.0")

  # s.licenses = %w(LGPLv3) # accessor not compatible with older RubyGems
end
