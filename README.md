# Stateful

A simple state machine gem. Works with plain ruby objects and Mongoid. This gem aims
to keep things simple. It supports the following:

- Simple event model, just use plain ruby methods as your events and use the change_state helper to change the state.
- Supports virtual/grouped states that can be used to break down top level states into more granular sub-states.
- Utilizes ActiveSupport::Callbacks
- Simple hash structure for defining states and their possible transitions. No complicated DSL to learn.
- ActiveSupport is the only dependency.
- Very small code footprint.
- Mongoid support, automatically creates field, validations and scopes for you.
- Supports multiple state fields on the same object

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

    stateful default: :draft,
             events: [:publish, :unpublish, :approve, :complete, :mark_as_duplicate],
             states: {
                active: {
                    draft: :published,
                    published: {
                        needs_approval: [:approved, :duplicate, :draft],
                        approved: :closed
                    }
                },
                inactive: {
                    completed: nil,
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
project.draft? # => true
project.published? # => false
```

If you are using with Mongoid a field called state will automatically be created for you.

```ruby
class Project
    include Mongoid::Document # must be included first
    include Stateful

    field :published_at, type: Time

    stateful default: :draft,
             events: [:publish, :unpublish, :approve, :complete, :mark_as_duplicate],
             states: {
                active: {
                    draft: :published,
                    published: {
                        needs_approval: [:approved, :duplicate],
                        approved: :closed
                    }
                },
                inactive: {
                    completed: nil,
                    duplicate: nil
                }
             }


    # ...
end

# scopes are automatically created for you
Project.active.count
Project.published.count
```

### State Event Helpers

Two forms of change state methods are provided. There is the `change_state` method that was demonstrated above and then there is the `change_state!` version, which will raise an error instead of returning false if the state cannot be changed. 

`change_state` and `change_state!` are great low level utilities for changing the state of the object. However one issue is that sometimes you wish to provide both a bang and non-bang version of an event method. For example:

```ruby
def publish
  change_state(:needs_approval, :publish) do
    @published_at = Time.now
  end
end

def publish!
  change_state!(:needs_approval, :publish) do
    @published_at = Time.now
  end
end
```

Clearly this is not very dry. You could dry it up some more by using a callback, such as like this:

```ruby
def publish
  change_state(:needs_approval, :publish)
end

def publish!
  change_state!(:needs_approval, :publish)
end

before_publish do
  @published_at = Time.now
end
```

However this is not much better. Especially if there is additional logic contained within the publish methods. Because of this there is an additional class helper called `state_event` that you can use to define both `publish` and `publish!` while only having to declare the logic once. 

```ruby
state_event :publish do
  transition_to_state(:published) do
    @published_at = Time.now
  end
end
```

So what is going on here? The `state_event` method is being passed the event name, which causes both the `publish` and `publish!` methods to be created. Additionally there is a new instance method available that is called `transition_to_state(new_state)`. When this method is invoked it will in turn call either `change_state(new_state, :publish)` or `change_state!(new_state, :published)`

**Note** that `transition_to_state` is only meant to be called while one of the the event methods (in this example either `publish` or `publish!`) are being invoked. Calling this method any other time will raise an error.

**Also note** that currently `state_event` does not support handling method arguments. This is a planned feature but for now, if you need to support both bang and non-bang versions than you will need to use the lower level `change_state` method. 


## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
