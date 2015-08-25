class DiskWizardController < ApplicationController
  before_filter :admin_required
  # TODO: Clear mode(debug mode flag) only once at the beginning, not in every action
  before_filter :clear_mode, except: [:process_disk]

  layout 'wizard'

  NOTHING_OPTION = ''
  MOUNT_OPTION = '1'
  DELETE_OPTION = '2'
  CREATE_OPTION = '3'

  LVM_FSTYPE = "LVM2_member"

  # @return [Device Array] : Return array of Device objects, which are mounted(permanent or temporary) in the HDA.
  # Render the first step of the Disk-Wizard(DW)
  def select_device
    DebugLogger.info "--disk_wizard_start--"
    @mounted_disks = Device.mounts
  end

  # Expected key:values in @params:
  #   :device => Device path(Device.path) of the selected device from step 1
  # if no device is selected and the request type is HTTP POST, redirect to same step with flash error message
  # (HTTP GET method is used in 'back' event, when select to go back in a step)
  # else find the selected device and render second step of the Disk-Wizard(DW)
  def select_fs
    device = params[:device]
    DebugLogger.info "|#{self.class.name}|>|#{__method__}|:Device = #{device}"
    if not (device and request.post?)
      redirect_to disk_wizards_engine.select_path, :flash => {:error => "Please select a device to continue."}
      return false
    end
    if request.post?
      self.user_selections = {path: device, disk: device}
      @selected_disk = Device.find_with_unallocated(device)
    else
      @selected_disk = Device.find_with_unallocated(user_selections['path'])
    end
    @selected_disk = @selected_disk.exclude_mounted_partition
    @selected_disk = @selected_disk.exclude_small_unallocated_space
  end

  # Expected key:values in @params:
  #   :fs_type => An integer value which mapped to a supported filesystem type in Partition.PartitionType HashMap.
  #   :partition => System path of the selected partition(Device node)
  #   :format => A boolean value, if true selected partition will be formatted in to given filesystem type(fs_type)
  # Render third step of the wizard(options).
  def manage_disk
    format = params[:format]
    partition = params[:partition]
    fs_type = params[:fs_type].to_i
    if (partition and not fs_type)
      redirect_to defined?(disk_wizards_engine) ? disk_wizards_engine.file_system_path : file_system_path, :flash => {:error => "Please select a filesystem type to continue."}
      return false
    end
    if request.post?
      self.user_selections = {fs_type: fs_type, format: format, path: partition}
    end
    if partition.match(/^\/dev/).blank?
      device = Device.find_with_unallocated(user_selections['disk'])
      @selected_partiton = (device.partitions.select{|part| part.identifier == user_selections['path'] }).first
    else
      @selected_partiton = Device.find partition
    end
    if @selected_partiton.is_a? Partition and @selected_partiton.fstype.eql?(LVM_FSTYPE)
      flash[:error] = %Q[The Amahi team does not recommend use of LVM. <a href="https://www.amahi.org/faq/does-amahi-support-lvm" target="_blank">See why</a>.]
    end
  end

  # Expected key:values in @params:
  #   :options => An integer value which maps to the type of option, selected in step 3
  #   i.e if mount options is selected , :options value will be 1
  #     TODO: Improve structure of storing 'options' information, instead of simple number mapping
  #     TODO: i.e {mount: {label: 'label_name', mount_point: 'mount_point_name'} ,option2: {data_hash}}
  def confirmation
    unless params[:fs_type].blank?
     # create new partition with this file system
     fs_type = params[:fs_type].to_i
     partition_divider = params[:partition_divider].to_i
     self.user_selections = {fs_type: fs_type, partition_divider: partition_divider}
    end
    option = params[:option]
    label = params[:label].blank? ? nil : params[:label]
    if not( label.blank? ) and label.size > 11 and user_selections['fs_type'].eql?(3)
      redirect_to disk_wizards_engine.manage_path, :flash => {:error => "label have to be less than 12 character in FAT32"}
      return false
    end
    self.user_selections = {option: option, label: label}
    if user_selections['path'].match(/^\/dev/).blank?
      # is a unallocated space
      device = Device.find_with_unallocated(user_selections['disk'])
      @selected_disk = (device.partitions.select{|part| part.identifier == user_selections['path'] }).first
    else
      @selected_disk = Device.find(user_selections['path'])
    end
  end

  # Render progress page when click on apply button in 'confirmation' step
  #  Implicitly send HTTP POST request to process_disk action to start processing the operations
  # Expected key:values in @params:
  #   :debug => Integer value(1) if debug mode has selected in fourth step(confirmation), else nil
  def progress
    Device.progress = 0
    debug_mode = params[:debug]
    self.user_selections = {debug: debug_mode}
  end

  # An AJAX call is made to this action, from process.html.erb to start processing the queue
  # Create operation queue according to user selections(user_selections), and enqueue operations
  def process_disk
    if user_selections['option'].include?(CREATE_OPTION)
      identifier = user_selections['path']
      disk_path = user_selections['disk']
      self.user_selections = {identifier: identifier, path: disk_path}
    end
    path = user_selections['path']
    label = user_selections['label']
    DebugLogger.info "|#{self.class.name}|>|#{__method__}|:Selected disk/partition = #{path}"
    disk = Device.find path

    CommandExecutor.debug_mode = !!(self.user_selections['debug'])

    jobs_queue = JobQueue.new(user_selections.length)
    jobs_queue.enqueue({job_name: :pre_checks_job, job_para: {path: path}})

    if user_selections['format']
      para = {path: path, fs_type: user_selections['fs_type'], label: label}
      job_name = :format_job
      DebugLogger.info "|#{self.class.name}|>|#{__method__}|:Job_name = #{job_name}, para = #{para}"
      jobs_queue.enqueue({job_name: job_name, job_para: para})
    end

    unless user_selections['option'].blank?
      option = user_selections['option']
      if option.include?(DELETE_OPTION)
        if user_selections['path'].blank?
          redirect_to disk_wizards_engine.select_path, :flash => {:error => "You have to choose a partition"}
          return false
        end
        para = {partition: user_selections['path']}
        job_name = :delete_partition_job
        DebugLogger.info "|#{self.class.name}|>|#{__method__}|:Job_name = #{job_name}, para = #{para}"
        jobs_queue.enqueue({job_name: job_name, job_para: para})
      end

      if option.include?(CREATE_OPTION)
        para = {identifier: user_selections['identifier'], path: user_selections['disk'],
          fs_type: user_selections['fs_type'], partition_divider: user_selections['partition_divider']}
        job_name = :create_new_partition_job
        DebugLogger.info "|#{self.class.name}|>|#{__method__}|:Job_name = #{job_name}, para = #{para}"
        jobs_queue.enqueue({job_name: job_name, job_para: para})
      end

      if option.include?(MOUNT_OPTION)
        # mount new partition
        if option.include?(CREATE_OPTION)
          # send start sector as to be able to know which partition to mount
          device = Device.find_with_unallocated(user_selections['disk'])
          @selected_disk = (device.partitions.select{|part| part.identifier == user_selections['identifier'] }).first
          start_sector = @selected_disk.start_sector
        end

        para = {path: path, label: label, start_sector: start_sector}
        job_name = :mount_job
        jobs_queue.enqueue({job_name: job_name, job_para: para})
      end
    end

    jobs_queue.enqueue({job_name: :post_checks_job, job_para: {path: path}})
    result = jobs_queue.process_queue disk
    if result == true
      Device.progress = 100
      redirect_to(disk_wizards_engine.complete_path)
    else
      Device.progress = -1
      session[:exception] = result.inspect
      redirect_to(disk_wizards_engine.error_path)
    end
  end

  # process_disk action redirects here if all operations are completed successfully
  def done
    @operations = CommandExecutor.operations_log
    flash[:success] = 'All disks operations have been completed successfully!'
    @user_selections = self.user_selections
  end

  # A helper method to return the user selections in the wizard
  # @return Hash
  def user_selections
    return JSON.parse session[:user_selections] rescue nil
  end

  helper_method :user_selections

  # Save user selections in a Rails session variable(Implicitly save data in browser cookie)
  # Accept @param [Hash] hash
  # Overwrite current user selection information with passed values.
  # Encode Hash object to JSON format(flatten the object,enabling store in a SESSION) and store in a session variable.
  def user_selections=(hash)
    current_user_selections = user_selections
    unless current_user_selections
      session[:user_selections] = hash.to_json and return
    end
    DebugLogger.info "|#{self.class.name}|>|#{__method__}|:New hash= #{hash}"
    hash.each do |key, value|
      current_user_selections[key] = value
    end
    session[:user_selections] = current_user_selections.to_json
    DebugLogger.info "|#{self.class.name}|>|#{__method__}|:Updated session[:user_selections] #{session[:user_selections]}"
  end


  # Show errors/exceptions to the user  if an error occurred while processing the operations.
  # Show the exceptions raised from the operating system level(stderr) via open3.
  def error
    @exception = session[:exception]
  end

  # Clear the debug_mode flag.
  # TODO: This is used as a before_filter with exceptions,this might cause redundant calls to this method(reset the flag which has been already cleared)
  def clear_mode
    CommandExecutor.debug_mode = nil
  end

end
