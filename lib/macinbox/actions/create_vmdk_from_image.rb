require 'fileutils'
require 'shellwords'

require 'macinbox/error'
require 'macinbox/logger'
require 'macinbox/task'

module Macinbox

  module Actions

    class CreateVMDKFromImage

      def initialize(opts)
        @input_image       = opts[:image_path]  or raise ArgumentError.new(":image_path not specified")
        @output_path       = opts[:vmdk_path]   or raise ArgumentError.new(":vmdk_path not specified")
        @vmware_fusion_app = opts[:vmware_path] or raise ArgumentError.new(":vmware_path not specified")

        @collector         = opts[:collector]   or raise ArgumentError.new(":collector not specified")
        @debug             = opts[:debug]

        raise Macinbox::Error.new("input image not found")   unless File.exist? @input_image
        raise Macinbox::Error.new("VMware Fusion not found") unless File.exist? @vmware_fusion_app
      end

      def run
        @temp_dir = Task.backtick %W[ /usr/bin/mktemp -d -t create_vmdk_from_image ]
        @collector.add_temp_dir @temp_dir

        Logger.info "Mounting the image..." do

          @collector.on_cleanup do
            %x( hdiutil detach -quiet -force #{@mountpoint.shellescape} > /dev/null 2>&1 ) if @mountpoint
            %x( diskutil eject #{@device.shellescape} > /dev/null 2>&1 ) if @device
          end

          @mountpoint = "#{@temp_dir}/image_mountpoint"

          FileUtils.mkdir @mountpoint

          @device = %x(
          	hdiutil attach #{@input_image.shellescape} -mountpoint #{@mountpoint.shellescape} -nobrowse -owners on |
          	grep _partition_scheme |
          	cut -f1 |
          	tr -d [:space:]
          )

          raise Macinbox::Error.new("failed to mount the image") unless File.exist? @device
        end

        Logger.info "Converting the image to VMDK format..." do
          rawdiskCreator = "#{@vmware_fusion_app}/Contents/Library/vmware-rawdiskCreator"
          vdiskmanager = "#{@vmware_fusion_app}/Contents/Library/vmware-vdiskmanager"
          Dir.chdir(@temp_dir) do
            Task.run %W[ #{rawdiskCreator} create  #{@device} fullDevice rawdisk lsilogic ]
            Task.run %W[ #{vdiskmanager} -t 0 -r rawdisk.vmdk macinbox.vmdk ]
          end
        end

        Logger.info "Moving the VMDK to the destination..." do
          FileUtils.chown ENV["SUDO_USER"], nil, "#{@temp_dir}/macinbox.vmdk"
          FileUtils.mv "#{@temp_dir}/macinbox.vmdk", @output_path
        end
        
      end

    end

  end

end
