# Builds only Plasma's task manager applet, renamed tech.shmuel.taskmanager, out of the
# plasma-desktop source tree (this file replaces the tree's top-level CMakeLists.txt).
cmake_minimum_required(VERSION 3.16)
project(spawnkit-taskmanager)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(ECM 6.22.0 REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})
include(KDEInstallDirs)
include(KDECMakeSettings)
include(KDECompilerSettings NO_POLICY_SCOPE)
include(ECMQtDeclareLoggingCategory)
include(ECMQmlModule)

find_package(Qt6 CONFIG REQUIRED COMPONENTS Core DBus Gui Qml Quick Widgets)
find_package(KF6 REQUIRED COMPONENTS Config I18n KIO Notifications Service WindowSystem)
find_package(Plasma REQUIRED)
find_package(PlasmaActivities REQUIRED)
find_package(PlasmaActivitiesStats REQUIRED)
find_package(LibNotificationManager CONFIG REQUIRED)
find_package(LibTaskManager CONFIG REQUIRED)
find_package(KSysGuard CONFIG REQUIRED)

add_subdirectory(applets/taskmanager)
