module Vaks
  # Powers off / reboots the machine through systemd-logind over the system D-Bus
  # (org.freedesktop.login1.Manager) — no shell commands involved. polkit decides
  # whether the calling user is allowed; an active local session normally is.
  module Power
    SERVICE   = "org.freedesktop.login1".freeze
    PATH      = "/org/freedesktop/login1".freeze
    INTERFACE = "org.freedesktop.login1.Manager".freeze

    class Error < StandardError; end

    # action: :poweroff or :reboot. Raises Power::Error when it is unavailable or denied.
    def self.call(action)
      require "dbus"

      manager = manager_interface
      can     = manager.send(action == :reboot ? "CanReboot" : "CanPowerOff").first
      raise Error, "logind says #{action} is not permitted (#{can})" unless can == "yes"

      # false = non-interactive: fail instead of prompting for polkit authentication
      action == :reboot ? manager.Reboot(false) : manager.PowerOff(false)
      true
    rescue LoadError
      raise Error, "ruby-dbus gem is not installed"
    rescue DBus::Error => e
      raise Error, e.message
    end

    def self.manager_interface
      object = DBus.system_bus[SERVICE].object(PATH)
      object.introspect
      object[INTERFACE]
    end
    private_class_method :manager_interface
  end
end
