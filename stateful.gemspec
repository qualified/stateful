# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'stateful/version'

Gem::Specification.new do |spec|
  spec.name          = "stateful"
  spec.version       = Stateful::VERSION
  spec.authors       = ["jake hoffner"]
  spec.email         = ["jake@codewars.com"]
  spec.description   = %q{A simple state machine gem}
  spec.summary       = %q{A simple state machine gem. Works with plain ruby objects and Mongoid. This gem aims
to keep things simple.}
  spec.homepage      = ""
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_dependency 'activesupport', '~> 5.2'
  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec"
  spec.add_development_dependency "mongoid", "~> 6.4"

end
