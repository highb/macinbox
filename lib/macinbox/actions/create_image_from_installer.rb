require 'fileutils'
require 'shellwords'
require 'io/console'

require 'macinbox/error'
require 'macinbox/logger'
require 'macinbox/task'

module Macinbox

  module Actions

    class CreateImageFromInstaller

      def initialize(opts)
        @installer_app     = opts[:installer_path]  or raise ArgumentError.new(":installer_path not specified")
        @output_path       = opts[:image_path]      or raise ArgumentError.new(":image_path not specified")
        @vmware_fusion_app = opts[:vmware_path]     or raise ArgumentError.new(":vmware_path not specified")

        @disk_size         = opts[:disk_size]       or raise ArgumentError.new(":disk_size not specified")
        @short_name        = opts[:short_name]      or raise ArgumentError.new(":short_name not specified")
        @full_name         = opts[:full_name]       or raise ArgumentError.new(":full_name not specified")
        @password          = opts[:password]        or raise ArgumentError.new(":password not specified")

        @auto_login        = opts[:auto_login]
        @skip_mini_buddy   = opts[:skip_mini_buddy]
        @hidpi             = opts[:hidpi]

        @collector         = opts[:collector]       or raise ArgumentError.new(":collector not specified")
        @debug             = opts[:debug]

        raise Macinbox::Error.new("installer app not found")     unless File.exist? @installer_app
        raise Macinbox::Error.new("VMware Fusion app not found") unless File.exist? @vmware_fusion_app
      end

      def run
        create_temp_dir
        check_macos_versions
        create_scratch_image
        install_macos
        install_vmware_tools
        set_spc_kextpolicy
        automate_user_account_creation
        automate_vagrant_ssh_key_installation
        enable_passwordless_sudo
        enable_sshd
        enable_hidpi
        save_image
      end

      def create_temp_dir
        @temp_dir = Task.backtick %W[ /usr/bin/mktemp -d -t create_image_from_installer ]
        @collector.add_temp_dir @temp_dir
      end

      def check_macos_versions
        Logger.info "Checking macOS versions..." do
          @install_info_plist = "#{@installer_app}/Contents/SharedSupport/InstallInfo.plist"
        	raise Macinbox::Error.new("InstallInfo.plist not found in installer app bundle") unless File.exist? @install_info_plist

          installer_os_version = Task.backtick %W[ /usr/libexec/PlistBuddy -c #{'Print :System\ Image\ Info:version'} #{@install_info_plist} ]
          installer_os_version_components = installer_os_version.split(".") rescue [0, 0, 0]
          installer_os_version_major = installer_os_version_components[0]
          installer_os_version_minor = installer_os_version_components[1]
          Logger.info "Installer macOS version detected: #{installer_os_version}" if @debug

          host_os_version = Task.backtick %W[ sw_vers -productVersion ]
          host_os_version_components = host_os_version.split(".") rescue [0, 0, 0]
          host_os_version_major = host_os_version_components[0]
          host_os_version_minor = host_os_version_components[1]
          Logger.info "Host macOS version detected: #{host_os_version}" if @debug

          if installer_os_version_major != host_os_version_major || installer_os_version_minor != host_os_version_minor
          	raise Macinbox::Error.new("host OS version (#{host_os_version}) and installer OS version (#{installer_os_version}) do not match")
          end
        end
      end

      def create_scratch_image
        Logger.info "Creating and attaching a new blank disk image..." do
          @collector.on_cleanup do
            %x( hdiutil detach -quiet -force #{@scratch_mountpoint.shellescape} > /dev/null 2>&1 ) if @scratch_mountpoint
          end
          @scratch_mountpoint = "#{@temp_dir}/scratch_mountpoint"
          @scratch_image = "#{@temp_dir}/scratch.sparseimage"
          FileUtils.mkdir @scratch_mountpoint
          quiet_flag = @debug ? [] : %W[ -quiet ]
          Task.run %W[ hdiutil create -size #{@disk_size}g -type SPARSE -fs HFS+J -volname #{"Macintosh HD"} -uid 0 -gid 80 -mode 1775 #{@scratch_image} ] + quiet_flag
          Task.run %W[ hdiutil attach #{@scratch_image} -mountpoint #{@scratch_mountpoint} -nobrowse -owners on ] + quiet_flag
        end
      end

      def install_macos
        Logger.info "Installing macOS..." do
          activity = Logger.prefix + "installer"
          cmd = %W[ installer -verboseR -dumplog -pkg #{@install_info_plist} -target #{@scratch_mountpoint} ]
          opts = @debug ? {} : { :err => [:child, :out] }
          Task.run_with_progress activity, cmd, opts do |line|
            /^installer:%(.*)$/.match(line)[1].to_f rescue nil
          end
        end
      end

      def install_vmware_tools
        Logger.info "Installing the VMware Tools..." do

          @collector.on_cleanup do
            %x( hdiutil detach -quiet -force #{@tools_mountpoint.shellescape} > /dev/null 2>&1 ) if @tools_mountpoint
          end

          @tools_mountpoint = "#{@temp_dir}/tools_mountpoint"
          FileUtils.mkdir @tools_mountpoint

          tools_image = "#{@vmware_fusion_app}/Contents/Library/isoimages/darwin.iso"
          tools_package = "#{@tools_mountpoint}/Install VMware Tools.app/Contents/Resources/VMware Tools.pkg"
          tools_package_dir = "#{@temp_dir}/tools_package"

          quiet_flag = @debug ? [] : %W[ -quiet ]

          Task.run %W[ hdiutil attach #{tools_image} -mountpoint #{@tools_mountpoint} -nobrowse ] + quiet_flag
          Task.run %W[ pkgutil --expand #{tools_package} #{tools_package_dir} ]
          Task.run %W[ ditto -x -z #{tools_package_dir}/files.pkg/Payload #{@scratch_mountpoint} ]

          scratch_vmhgfs_filesystem_resources = "#{@scratch_mountpoint}/Library/Filesystems/vmhgfs.fs/Contents/Resources"

          FileUtils.mkdir_p scratch_vmhgfs_filesystem_resources
          FileUtils.ln_s "/Library/Application Support/VMware Tools/mount_vmhgfs", "#{scratch_vmhgfs_filesystem_resources}/"
        end
      end

      def set_spc_kextpolicy
        Logger.info "Setting the KextPolicy to allow loading the VMware kernel extensions..." do
          scratch_spc_kextpolicy = "#{@scratch_mountpoint}/private/var/db/SystemPolicyConfiguration/KextPolicy"
          Task.run_with_input ["sqlite3", scratch_spc_kextpolicy] do |pipe|
            pipe.write <<~EOF
            	PRAGMA foreign_keys=OFF;
            	BEGIN TRANSACTION;
            	CREATE TABLE kext_load_history_v3 ( path TEXT PRIMARY KEY, team_id TEXT, bundle_id TEXT, boot_uuid TEXT, created_at TEXT, last_seen TEXT, flags INTEGER );
            	CREATE TABLE kext_policy ( team_id TEXT, bundle_id TEXT, allowed BOOLEAN, developer_name TEXT, flags INTEGER, PRIMARY KEY (team_id, bundle_id) );
            	INSERT INTO kext_policy VALUES('EG7KH642X6','com.vmware.kext.VMwareGfx',1,'VMware, Inc.',1);
            	INSERT INTO kext_policy VALUES('EG7KH642X6','com.vmware.kext.vmmemctl',1,'VMware, Inc.',1);
            	INSERT INTO kext_policy VALUES('EG7KH642X6','com.vmware.kext.vmhgfs',1,'VMware, Inc.',1);
            	CREATE TABLE kext_policy_mdm ( team_id TEXT, bundle_id TEXT, allowed BOOLEAN, payload_uuid TEXT, PRIMARY KEY (team_id, bundle_id) );
            	CREATE TABLE settings ( name TEXT, value TEXT, PRIMARY KEY (name) );
            	COMMIT;
            EOF
          end
        end
      end

      def automate_user_account_creation
        Logger.info "Configuring the primary user account..." do
          scratch_installer_configuration_file = "#{@scratch_mountpoint}/private/var/db/.InstallerConfiguration"
          File.write scratch_installer_configuration_file, <<~EOF
          	<?xml version="1.0" encoding="UTF-8"?>
          	<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          	<plist version="1.0">
          	<dict>
          		<key>Users</key>
          		<array>
          			<dict>
          				<key>admin</key>
          				<true/>
          				<key>autologin</key>
          				<#{@auto_login ? true : false}/>
          				<key>fullName</key>
          				<string>#{@full_name}</string>
          				<key>shortName</key>
          				<string>#{@short_name}</string>
          				<key>password</key>
          				<string>#{@password}</string>
          				<key>skipMiniBuddy</key>
          				<#{@skip_mini_buddy ? true : false}/>
          			</dict>
          		</array>
          	</dict>
          	</plist>
          EOF
        end
      end

      def automate_vagrant_ssh_key_installation
        if @short_name == "vagrant"
        	Logger.info "Installing the default insecure vagrant ssh key..." do
            scratch_rc_installer_cleanup = "#{@scratch_mountpoint}/private/etc/rc.installer_cleanup"
            scratch_rc_vagrant = "#{@scratch_mountpoint}/private/etc/rc.vagrant"
            File.write scratch_rc_installer_cleanup, <<~EOF
          		#!/bin/sh
          		rm /etc/rc.installer_cleanup
          		/etc/rc.vagrant &
          		exit 0
          	EOF
          	FileUtils.chmod 0755, scratch_rc_installer_cleanup
          	File.write scratch_rc_vagrant, <<~EOF
          		#!/bin/sh
          		rm /etc/rc.vagrant
          		while [ ! -e /Users/vagrant ]; do
          			sleep 1
          		done
          		if [ ! -e /Users/vagrant/.ssh ]; then
          			mkdir /Users/vagrant/.ssh
          			chmod 0700 /Users/vagrant/.ssh
          			chown `stat -f %u /Users/vagrant` /Users/vagrant/.ssh
          		fi
          		echo "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzIw+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q9qgCgzUFtdOKLv6IedplqoPkcmF0aYet2PkEDo3MlTBckFXPITAMzF8dJSIFo9D8HfdOV0IAdx4O7PtixWKn5y2hMNG0zQPyUecp4pzC6kivAIhyfHilFR61RGL+GPXQ2MWZWFYbAGjyiYJnAmCP3NOTd0jMZEnDkbUvxhMmBYSdETk1rRgm+R4LOzFUGaHqHDLKLX+FIPKcF96hrucXzcWyLbIbEgE98OHlnVYCzRdK8jlqm8tehUc9c9WhQ== vagrant insecure public key" >> /Users/vagrant/.ssh/authorized_keys
          		chmod 0600 /Users/vagrant/.ssh/authorized_keys
          		chown `stat -f %u /Users/vagrant` /Users/vagrant/.ssh/authorized_keys
          	EOF
          	FileUtils.chmod 0755, scratch_rc_vagrant
          end
        end
      end

      def enable_passwordless_sudo
        Logger.info "Enabling password-less sudo..." do
          scratch_sudoers_d_user_rule_file = "#{@scratch_mountpoint}/private/etc/sudoers.d/#{@short_name}"
          File.write scratch_sudoers_d_user_rule_file, <<~EOF
          	#{@short_name} ALL=(ALL) NOPASSWD: ALL
          EOF
          FileUtils.chmod 0440, scratch_sudoers_d_user_rule_file
        end
      end

      def enable_sshd
        Logger.info "Enabling sshd..." do
          scratch_launchd_disabled_plist = "#{@scratch_mountpoint}/private/var/db/com.apple.xpc.launchd/disabled.plist"
          opts = @debug ? {} : { :out => File::NULL }
          Task.run %W[ /usr/libexec/PlistBuddy -c #{'Add :com.openssh.sshd bool False'} #{scratch_launchd_disabled_plist} ] + [opts]
        end
      end


      def enable_hidpi
        if @hidpi
        	Logger.info "Enabling HiDPI resolutions..." do
            scratch_windowserver_preferences = "#{@scratch_mountpoint}/Library/Preferences/com.apple.windowserver.plist"
          	File.write scratch_windowserver_preferences, <<~EOF
          		<?xml version="1.0" encoding="UTF-8"?>
          		<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          		<plist version="1.0">
          		<dict>
          			<key>DisplayResolutionEnabled</key>
          			<true/>
          		</dict>
          		</plist>
          	EOF
          end
        end
      end

      def save_image
        Logger.info "Saving the image..." do
          Task.run %W[ hdiutil detach -quiet #{@scratch_mountpoint} ]
          FileUtils.mv @scratch_image, "#{@temp_dir}/macinbox.dmg"
          FileUtils.chown ENV["SUDO_USER"], nil, "#{@temp_dir}/macinbox.dmg"
          FileUtils.mv "#{@temp_dir}/macinbox.dmg", @output_path
        end
      end

    end

  end

end
