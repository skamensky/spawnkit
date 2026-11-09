# Builds only Plasma's notifications applet, renamed tech.shmuel.notifications, out of the
# plasma-workspace source tree (this file replaces the tree's top-level CMakeLists.txt).
cmake_minimum_required(VERSION 3.16)
project(spawnkit-notifications)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(ECM 6.22.0 REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})
include(KDEInstallDirs)
include(KDECMakeSettings)
include(KDECompilerSettings NO_POLICY_SCOPE)
include(ECMQtDeclareLoggingCategory)
include(ECMQmlModule)

find_package(Qt6 CONFIG REQUIRED COMPONENTS Core DBus Gui Qml Quick Widgets WaylandClient)
find_package(Qt6GuiPrivate REQUIRED NO_MODULE)
find_package(Qt6WaylandClientPrivate REQUIRED NO_MODULE)
find_package(KF6 REQUIRED COMPONENTS Config CoreAddons GlobalAccel I18n KIO Notifications)
find_package(Plasma REQUIRED)
find_package(PlasmaQuick REQUIRED)
find_package(LibNotificationManager CONFIG REQUIRED)
find_package(PlasmaWaylandProtocols 1.6 REQUIRED)
find_package(Wayland REQUIRED COMPONENTS Client)

add_subdirectory(applets/notifications)
