import QtQuick
import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: i18n("General")
        icon: "configure"
        source: "configGeneral.qml"
    }
    ConfigCategory {
        name: i18n("Providers")
        icon: "network-connect"
        source: "configProviders.qml"
    }
    ConfigCategory {
        name: i18n("Agents")
        icon: "system-run"
        source: "configAgents.qml"
    }
    ConfigCategory {
        name: i18n("Appearance")
        icon: "preferences-desktop-theme"
        source: "configAppearance.qml"
    }
    ConfigCategory {
        name: i18n("Notifications")
        icon: "preferences-desktop-notification"
        source: "configNotifications.qml"
    }
    ConfigCategory {
        name: i18n("Hosts")
        icon: "network-server"
        source: "configHosts.qml"
    }
}
