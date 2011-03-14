require 'puppet'
require 'puppet/util/filetype'
require 'puppet/util/fileparsing'

# This provider can be used as the parent class for a provider that
# parses and generates files.  Its content must be loaded via the
# 'prefetch' method, and the file will be written when 'flush' is called
# on the provider instance.  At this point, the file is written once
# for every provider instance.
#
# Once the provider prefetches the data, it's the resource's job to copy
# that data over to the @is variables.
class Puppet::Provider::ParsedFile < Puppet::Provider
  extend Puppet::Util::FileParsing

  class << self
    attr_accessor :default_target, :target
  end

  attr_accessor :property_hash

  def self.clean(hash)
    newhash = hash.dup
    [:record_type, :on_disk].each do |p|
      newhash.delete(p) if newhash.include?(p)
    end

    newhash
  end

  def self.clear
    @target_objects.clear
    @records.clear
  end

  def self.filetype
    @filetype ||= Puppet::Util::FileType.filetype(:flat)
  end

  def self.filetype=(type)
    if type.is_a?(Class)
      @filetype = type
    elsif klass = Puppet::Util::FileType.filetype(type)
      @filetype = klass
    else
      raise ArgumentError, "Invalid filetype #{type}"
    end
  end

  # Flush all of the targets for which there are modified records.  The only
  # reason we pass a record here is so that we can add it to the stack if
  # necessary -- it's passed from the instance calling 'flush'.
  def self.flush(record)
    # Make sure this record is on the list to be flushed.
    unless record[:on_disk]
      record[:on_disk] = true
      @records << record

      # If we've just added the record, then make sure our
      # target will get flushed.
      modified(record[:target] || default_target)
    end

    return unless defined?(@modified) and ! @modified.empty?

    flushed = []
    @modified.sort { |a,b| a.to_s <=> b.to_s }.uniq.each do |target|
      Puppet.debug "Flushing #{@resource_type.name} provider target #{target}"
      flush_target(target)
      flushed << target
    end

    @modified.reject! { |t| flushed.include?(t) }
  end

  # Make sure our file is backed up, but only back it up once per transaction.
  # We cheat and rely on the fact that @records is created on each prefetch.
  def self.backup_target(target)
    return nil unless target_object(target).respond_to?(:backup)

    @backup_stats ||= {}
    return nil if @backup_stats[target] == @records.object_id

    target_object(target).backup
    @backup_stats[target] = @records.object_id
  end

  # Flush all of the records relating to a specific target.
  def self.flush_target(target)
    backup_target(target)

    records = target_records(target).reject { |r|
      r[:ensure] == :absent
    }
    target_object(target).write(to_file(records))
  end

  # Return the header placed at the top of each generated file, warning
  # users that modifying this file manually is probably a bad idea.
  def self.header
%{# HEADER: This file was autogenerated at #{Time.now}
# HEADER: by puppet.  While it can still be managed manually, it
# HEADER: is definitely not recommended.\n}
  end

  # Add another type var.
  def self.initvars
    @records = []
    @target_objects = {}

    @target = nil

    # Default to flat files
    @filetype ||= Puppet::Util::FileType.filetype(:flat)
    super
  end

  # Return a list of all of the records we can find.
  def self.instances
    targets.collect do |target|
      prefetch_target(target)
    end.flatten.reject { |r| skip_record?(r) }.collect do |record|
      new(record)
    end
  end

  # Override the default method with a lot more functionality.
  def self.mk_resource_methods
    [resource_type.validproperties, resource_type.parameters].flatten.each do |attr|
      attr = symbolize(attr)
      define_method(attr) do
#                if @property_hash.empty?
#                    # Note that this swaps the provider out from under us.
#                    prefetch
#                    if @resource.provider == self
#                        return @property_hash[attr]
#                    else
#                        return @resource.provider.send(attr)
#                    end
#                end
        # If it's not a valid field for this record type (which can happen
        # when different platforms support different fields), then just
        # return the should value, so the resource shuts up.
        if @property_hash[attr] or self.class.valid_attr?(self.class.name, attr)
          @property_hash[attr] || :absent
        else
          if defined?(@resource)
            @resource.should(attr)
          else
            nil
          end
        end
      end

      define_method(attr.to_s + "=") do |val|
        mark_target_modified
        @property_hash[attr] = val
      end
    end
  end

  # Always make the resource methods.
  def self.resource_type=(resource)
    super
    mk_resource_methods
  end

  # Mark a target as modified so we know to flush it.  This only gets
  # used within the attr= methods.
  def self.modified(target)
    @modified ||= []
    @modified << target unless @modified.include?(target)
  end

  # Retrieve all of the data from disk.  There are three ways to know
  # which files to retrieve:  We might have a list of file objects already
  # set up, there might be instances of our associated resource and they
  # will have a path parameter set, and we will have a default path
  # set.  We need to turn those three locations into a list of files,
  # prefetch each one, and make sure they're associated with each appropriate
  # resource instance.
  def self.prefetch(resources = nil)
    # Reset the record list.
    @records = prefetch_all_targets(resources)

    match_providers_with_resources(resources)
  end

  def self.match_providers_with_resources(resources)
    return unless resources
    matchers = resources.dup
    @records.each do |record|
      # Skip things like comments and blank lines
      next if skip_record?(record)

      if name = record[:name] and resource = resources[name]
        resource.provider = new(record)
      elsif respond_to?(:match)
        if resource = match(record, matchers)
          # Remove this resource from circulation so we don't unnecessarily try to match
          matchers.delete(resource.title)
          record[:name] = resource[:name]
          resource.provider = new(record)
        end
      end
    end
  end

  def self.prefetch_all_targets(resources)
    records = []
    targets(resources).each do |target|
      records += prefetch_target(target)
    end
    records
  end

  # Prefetch an individual target.
  def self.prefetch_target(target)
    target_records = retrieve(target).each do |r|
      r[:on_disk] = true
      r[:target] = target
      r[:ensure] = :present
    end

    target_records = prefetch_hook(target_records) if respond_to?(:prefetch_hook)

    raise Puppet::DevError, "Prefetching #{target} for provider #{self.name} returned nil" unless target_records

    target_records
  end

  # Is there an existing record with this name?
  def self.record?(name)
    return nil unless @records
    @records.find { |r| r[:name] == name }
  end

  # Retrieve the text for the file. Returns nil in the unlikely
  # event that it doesn't exist.
  def self.retrieve(path)
    # XXX We need to be doing something special here in case of failure.
    text = target_object(path).read
    if text.nil? or text == ""
      # there is no file
      return []
    else
      # Set the target, for logging.
      old = @target
      begin
        @target = path
        return self.parse(text)
      rescue Puppet::Error => detail
        detail.file = @target
        raise detail
      ensure
        @target = old
      end
    end
  end

  # Should we skip the record?  Basically, we skip text records.
  # This is only here so subclasses can override it.
  def self.skip_record?(record)
    record_type(record[:record_type]).text?
  end

  # Initialize the object if necessary.
  def self.target_object(target)
    @target_objects[target] ||= filetype.new(target)

    @target_objects[target]
  end

  # Find all of the records for a given target
  def self.target_records(target)
    @records.find_all { |r| r[:target] == target }
  end

  # Find a list of all of the targets that we should be reading.  This is
  # used to figure out what targets we need to prefetch.
  def self.targets(resources = nil)
    targets = []
    # First get the default target
    raise Puppet::DevError, "Parsed Providers must define a default target" unless self.default_target
    targets << self.default_target

    # Then get each of the file objects
    targets += @target_objects.keys

    # Lastly, check the file from any resource instances
    if resources
      resources.each do |name, resource|
        if value = resource.should(:target)
          targets << value
        end
      end
    end

    targets.uniq.compact
  end

  def self.to_file(records)
    text = super
    header + text
  end

  def create
    @resource.class.validproperties.each do |property|
      if value = @resource.should(property)
        @property_hash[property] = value
      end
    end
    mark_target_modified
    (@resource.class.name.to_s + "_created").intern
  end

  def destroy
    # We use the method here so it marks the target as modified.
    self.ensure = :absent
    (@resource.class.name.to_s + "_deleted").intern
  end

  def exists?
    !(@property_hash[:ensure] == :absent or @property_hash[:ensure].nil?)
  end

  # Write our data to disk.
  def flush
    # Make sure we've got a target and name set.

    # If the target isn't set, then this is our first modification, so
    # mark it for flushing.
    unless @property_hash[:target]
      @property_hash[:target] = @resource.should(:target) || self.class.default_target
      self.class.modified(@property_hash[:target])
    end
    @resource.class.key_attributes.each do |attr|
      @property_hash[attr] ||= @resource[attr]
    end

    self.class.flush(@property_hash)

    #@property_hash = {}
  end

  def initialize(record)
    super

    # The 'record' could be a resource or a record, depending on how the provider
    # is initialized.  If we got an empty property hash (probably because the resource
    # is just being initialized), then we want to set up some defualts.
    @property_hash = self.class.record?(resource[:name]) || {:record_type => self.class.name, :ensure => :absent} if @property_hash.empty?
  end

  # Retrieve the current state from disk.
  def prefetch
    raise Puppet::DevError, "Somehow got told to prefetch with no resource set" unless @resource
    self.class.prefetch(@resource[:name] => @resource)
  end

  def record_type
    @property_hash[:record_type]
  end

  private

  # Mark both the resource and provider target as modified.
  def mark_target_modified
    if defined?(@resource) and restarget = @resource.should(:target) and restarget != @property_hash[:target]
      self.class.modified(restarget)
    end
    self.class.modified(@property_hash[:target]) if @property_hash[:target] != :absent and @property_hash[:target]
  end
end
