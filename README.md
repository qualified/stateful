# Stateful

A simple state machine gem. Works with plain ruby objects and Mongoid. This gem aims
to keep things simple. It supports the following:

- Single state attribute/field per object
- Simple event model, just use plain ruby methods as your events and use the change_state helper to change the state.
- Supports virtual/grouped states that can be used to break down top level states into more granular sub-states.
- Utilizes ActiveSupport::Callbacks
- Simple hash structure for defining states and their possible transitions. No complicated DSL to learn.
- ActiveSupport is the only dependency.
- Very small code footprint.
- Mongoid support, automatically creates field, validations and scopes for you.

## Installation

Add this line to your application's Gemfile:

    gem 'stateful'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install stateful

## Usage

```ruby
class Project
    include Stateful

    attr_reader :published_at

    stateful default: :new,
             events: [:publish, :unpublish, :approve, :close, :mark_as_duplicate],
             states: {
                active: {
                    new: :published,
                    published: {
                        needs_approval: [:approved, :duplicate, :new],
                        approved: :closed
                    }
                },
                inactive: {
                    closed: nil,
                    duplicate: nil
                }
             }

    def publish
        # change the state to needs_approval and fire publish events. The block will only be
        # called if the state can successfully be changed.
        change_state(:needs_approval, :publish) do
            @published_at = Time.now
        end
    end

    # use callbacks if you want
    after_publish do |project|
        NotificationService.notify_project_published(project)
    end

    # define other event methods ...
end

project = Project.new
project.active? # => true
project.new? # => true
project.published? # => false
```

If you are using with Mongoid a field called state will automatically be created for you.

```ruby
class Project
    include Mongoid::Document # must be included first
    include Stateful

    field :published_at, type: Time

    stateful default: :new,
             events: [:publish, :unpublish, :approve, :close, :mark_as_duplicate],
             states: {
                active: {
                    new: :published,
                    published: {
                        needs_approval: [:approved, :duplicate],
                        approved: :closed
                    }
                },
                inactive: {
                    closed: nil,
                    duplicate: nil
                }
             }


    # ...
end

# scopes are automatically created for you
Project.active.count
Project.published.count
```

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
