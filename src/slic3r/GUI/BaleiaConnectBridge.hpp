#ifndef slic3r_GUI_BaleiaConnectBridge_hpp_
#define slic3r_GUI_BaleiaConnectBridge_hpp_

#include <boost/filesystem/path.hpp>

#include <string>

namespace Slic3r {
namespace GUI {

struct BaleiaConnectJob
{
    boost::filesystem::path source_path;
    std::string             display_name;
    std::string             printer_id;
    std::string             printer_name;
    std::string             printer_model;
    std::string             ams_mapping;
    std::string             ams_mapping2;
    std::string             ams_mapping_info;
    std::string             nozzles_info;
    std::string             bed_type;
    bool                    use_ams{false};
    bool                    bed_leveling{false};
    bool                    flow_calibration{false};
    bool                    timelapse{false};
};

namespace BaleiaConnect {

enum class ConnectionStatus
{
    Checking,
    Connected,
    Disconnected,
    Missing,
    Error
};

// Reads the heartbeat written by the hidden Connect companion. A stale or
// not-yet-created heartbeat is Checking, never optimistically Connected.
ConnectionStatus connection_status();

// Enables the portable data_dir shipped with Baleia. On its first run, the
// existing OrcaSlicer profile is copied into it. If the live directory was
// lost, the latest complete Baleia backup is restored instead.
bool prepare_portable_data_directory(const boost::filesystem::path &application_root,
                                     const boost::filesystem::path &legacy_data_directory);

// Starts the small Windows companion that owns Bambu Connect's tray lifecycle
// and consumes queued print jobs. Calling this more than once is harmless.
bool start_helper();

// Atomically copies the final sliced package and its physical printer / AMS
// choices into BaleiaConnect/Fila. The helper sees only complete job files.
bool queue_job(const BaleiaConnectJob &job, std::string *error_message = nullptr);

// Creates an atomic snapshot of portable profiles and keeps the five newest.
void create_portable_backup();

boost::filesystem::path application_root();

} // namespace BaleiaConnect
} // namespace GUI
} // namespace Slic3r

#endif
