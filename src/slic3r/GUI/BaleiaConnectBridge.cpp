#include "BaleiaConnectBridge.hpp"

#include "libslic3r/Utils.hpp"

#include <boost/algorithm/string/predicate.hpp>
#include <boost/filesystem.hpp>
#include <boost/log/trivial.hpp>
#include <boost/nowide/convert.hpp>
#include <boost/nowide/fstream.hpp>
#include <nlohmann/json.hpp>

#include <wx/stdpaths.h>
#include <wx/utils.h>

#include <algorithm>
#include <ctime>
#include <functional>
#include <iomanip>
#include <set>
#include <sstream>
#include <stdexcept>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#endif

namespace Slic3r {
namespace GUI {
namespace BaleiaConnect {

namespace fs = boost::filesystem;
using json   = nlohmann::json;

namespace {

constexpr std::time_t queue_retention_seconds = 24 * 60 * 60;
constexpr std::size_t backup_retention_count   = 5;

const char *initialized_marker_name = ".baleia-initialized";
const char *backup_marker_name      = ".baleia-backup-complete";

fs::path helper_script(const fs::path &root)
{
    return root / "resources" / "baleia" / "BaleiaConnectHelper.ps1";
}

fs::path queue_root(const fs::path &root)
{
    return root / "BaleiaConnect";
}

bool ignored_live_entry(const fs::path &path)
{
    const std::string name = path.filename().string();
    return name == "BALEIA_PORTATIL.txt" || name == initialized_marker_name ||
           name == backup_marker_name || name == ".DS_Store" || name == "Thumbs.db";
}

bool has_live_data(const fs::path &directory)
{
    boost::system::error_code ec;
    if (!fs::is_directory(directory, ec))
        return false;

    fs::directory_iterator it(directory, ec);
    const fs::directory_iterator end;
    while (!ec && it != end) {
        const fs::path candidate = it->path();
        if (!ignored_live_entry(candidate)) {
            if (fs::is_directory(candidate, ec)) {
                ec.clear();
                if (has_live_data(candidate))
                    return true;
            } else if (fs::is_regular_file(candidate, ec)) {
                return true;
            }
        }
        ec.clear();
        it.increment(ec);
    }
    return false;
}

bool ignored_backup_entry(const fs::path &path)
{
    const std::string name = path.filename().string();
    static const std::set<std::string> ignored_directories{
        "log", "cache", "tmp", "temp", "downloads"
    };

    if (fs::is_directory(path) && ignored_directories.count(name) != 0)
        return true;
    if (name == "instance_check.lock" || boost::algorithm::iends_with(name, ".lock") ||
        boost::algorithm::iends_with(name, ".tmp"))
        return true;
    return false;
}

void copy_tree(const fs::path &source, const fs::path &target, bool filter_runtime_files)
{
    boost::system::error_code ec;
    if (!fs::is_directory(source, ec))
        return;

    fs::create_directories(target);
    for (fs::directory_iterator it(source), end; it != end; ++it) {
        const fs::path src = it->path();
        if (src.filename() == backup_marker_name)
            continue;
        if (filter_runtime_files && ignored_backup_entry(src))
            continue;

        const fs::path dst = target / src.filename();
        if (fs::is_directory(src)) {
            copy_tree(src, dst, filter_runtime_files);
        } else if (fs::is_regular_file(src)) {
            fs::copy_file(src, dst, fs::copy_option::overwrite_if_exists);
        }
    }
}

void write_marker(const fs::path &path, const std::string &contents)
{
    boost::nowide::ofstream stream(path.string(), std::ios::binary | std::ios::trunc);
    if (!stream)
        throw std::runtime_error("could not create marker file");
    stream << contents;
}

std::string utc_timestamp(const char *format)
{
    const std::time_t now = std::time(nullptr);
    std::tm utc{};
#ifdef _WIN32
    gmtime_s(&utc, &now);
#else
    gmtime_r(&now, &utc);
#endif
    std::ostringstream stream;
    stream << std::put_time(&utc, format);
    return stream.str();
}

fs::path latest_complete_backup(const fs::path &backups_root)
{
    std::vector<fs::path> candidates;
    boost::system::error_code ec;
    if (!fs::is_directory(backups_root, ec))
        return {};

    for (fs::directory_iterator it(backups_root, ec), end; !ec && it != end; it.increment(ec)) {
        const fs::path candidate = it->path();
        if (fs::is_directory(candidate, ec) && fs::exists(candidate / backup_marker_name, ec))
            candidates.emplace_back(candidate);
        ec.clear();
    }
    std::sort(candidates.begin(), candidates.end(), std::greater<fs::path>());
    return candidates.empty() ? fs::path{} : candidates.front();
}

void cleanup_stale_queue_files(const fs::path &root)
{
    const std::time_t cutoff = std::time(nullptr) - queue_retention_seconds;
    boost::system::error_code ec;
    if (!fs::is_directory(root, ec))
        return;

    for (fs::recursive_directory_iterator it(root, ec), end; !ec && it != end; it.increment(ec)) {
        const fs::path candidate = it->path();
        if (!fs::is_regular_file(candidate, ec)) {
            ec.clear();
            continue;
        }
        const std::time_t modified = fs::last_write_time(candidate, ec);
        if (!ec && modified < cutoff)
            fs::remove(candidate, ec);
        ec.clear();
    }
}

json parsed_or_text(const std::string &value)
{
    if (value.empty())
        return json::array();
    json parsed = json::parse(value, nullptr, false);
    return parsed.is_discarded() ? json(value) : parsed;
}

std::string path_utf8(const fs::path &path)
{
#ifdef _WIN32
    return boost::nowide::narrow(path.wstring());
#else
    return path.string();
#endif
}

} // namespace

fs::path application_root()
{
    return fs::path(wxStandardPaths::Get().GetExecutablePath().ToUTF8().data()).parent_path();
}

bool prepare_portable_data_directory(const fs::path &root, const fs::path &legacy_data_directory)
{
    const fs::path portable = root / "data_dir";
    const fs::path backups  = root / "Backups";

    // This leaves ordinary source builds alone. Installed Baleia packages are
    // identified by the companion resource, an existing portable directory,
    // or a backup that can recover a lost directory.
    if (!fs::exists(helper_script(root)) && !fs::exists(portable) && !fs::exists(backups))
        return false;

    try {
        fs::create_directories(portable);
        const fs::path portable_temp = queue_root(root) / "Temp";
        fs::create_directories(portable_temp);

        if (!has_live_data(portable)) {
            const fs::path backup = latest_complete_backup(backups);
            if (!backup.empty()) {
                copy_tree(backup, portable, false);
            } else if (!legacy_data_directory.empty() && legacy_data_directory != portable &&
                       fs::is_directory(legacy_data_directory) && has_live_data(legacy_data_directory)) {
                copy_tree(legacy_data_directory, portable, true);
            }
        }

        write_marker(portable / initialized_marker_name,
                     "Baleia Orca portable data initialized at " + utc_timestamp("%Y-%m-%dT%H:%M:%SZ") + "\n");
        set_data_dir(portable.string());
        set_temporary_dir(portable_temp.string());
        return true;
    } catch (const std::exception &ex) {
        BOOST_LOG_TRIVIAL(error) << "Baleia portable data initialization failed: " << ex.what();
        return false;
    }
}

bool start_helper()
{
#ifndef _WIN32
    return false;
#else
    try {
        const fs::path root   = application_root();
        const fs::path script = helper_script(root);
        if (!fs::is_regular_file(script))
            return false;

        const fs::path bridge_root = queue_root(root);
        fs::create_directories(bridge_root / "Fila");
        fs::create_directories(bridge_root / "Processando");
        fs::create_directories(bridge_root / "Erros");
        fs::create_directories(bridge_root / "Runtime");
        cleanup_stale_queue_files(bridge_root / "Fila");
        cleanup_stale_queue_files(bridge_root / "Processando");
        cleanup_stale_queue_files(bridge_root / "Erros");

        std::wstring command = L"powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"";
        command += script.wstring();
        command += L"\" -ParentPid ";
        command += std::to_wstring(static_cast<unsigned long>(wxGetProcessId()));
        command += L" -Root \"";
        command += root.wstring();
        command += L"\"";

        STARTUPINFOW startup_info{};
        startup_info.cb = sizeof(startup_info);
        PROCESS_INFORMATION process_info{};
        const std::wstring working_directory = root.wstring();
        const BOOL started = ::CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE,
                                               CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, nullptr,
                                               working_directory.c_str(), &startup_info, &process_info);
        if (!started) {
            BOOST_LOG_TRIVIAL(error) << "Could not start Baleia Connect helper, Windows error " << ::GetLastError();
            return false;
        }
        ::CloseHandle(process_info.hThread);
        ::CloseHandle(process_info.hProcess);
        return true;
    } catch (const std::exception &ex) {
        BOOST_LOG_TRIVIAL(error) << "Could not start Baleia Connect helper: " << ex.what();
        return false;
    }
#endif
}

bool queue_job(const BaleiaConnectJob &job, std::string *error_message)
{
    auto fail = [error_message](const std::string &message) {
        if (error_message)
            *error_message = message;
        BOOST_LOG_TRIVIAL(error) << "Baleia Connect queue: " << message;
        return false;
    };

#ifndef _WIN32
    return fail("Bambu Connect automation is available only on Windows.");
#else
    try {
        if (!fs::is_regular_file(job.source_path))
            return fail("The final sliced package was not found.");

        const fs::path root = application_root();
        if (!fs::is_regular_file(helper_script(root)))
            return fail("Baleia Connect helper is missing from the portable package.");

        const fs::path bridge_root = queue_root(root);
        const fs::path pending     = bridge_root / "Fila";
        fs::create_directories(pending);
        fs::create_directories(bridge_root / "Processando");
        fs::create_directories(bridge_root / "Erros");
        fs::create_directories(bridge_root / "Runtime");
        cleanup_stale_queue_files(bridge_root / "Fila");
        cleanup_stale_queue_files(bridge_root / "Processando");
        cleanup_stale_queue_files(bridge_root / "Erros");

        const std::string job_id = utc_timestamp("%Y%m%dT%H%M%SZ-") + fs::unique_path("%%%%-%%%%-%%%%").string();
        const fs::path file_path = pending / (job_id + ".gcode.3mf");
        const fs::path file_part = pending / (job_id + ".gcode.3mf.partial");
        const fs::path json_path = pending / (job_id + ".job.json");
        const fs::path json_part = pending / (job_id + ".job.json.partial");

        boost::system::error_code ec;
        fs::copy_file(job.source_path, file_part, fs::copy_option::overwrite_if_exists, ec);
        if (ec)
            return fail("Could not copy the final sliced package: " + ec.message());
        fs::rename(file_part, file_path, ec);
        if (ec) {
            fs::remove(file_part);
            return fail("Could not publish the final sliced package: " + ec.message());
        }

        json manifest{
            {"schema", 1},
            {"job_id", job_id},
            {"state", "pending"},
            {"created_utc", utc_timestamp("%Y-%m-%dT%H:%M:%SZ")},
            {"baleia_pid", static_cast<unsigned long>(wxGetProcessId())},
            {"file", path_utf8(file_path)},
            {"display_name", job.display_name},
            {"printer", {
                {"id", job.printer_id},
                {"name", job.printer_name},
                {"model", job.printer_model}
            }},
            {"mapping", {
                {"ams", parsed_or_text(job.ams_mapping)},
                {"ams_slots", parsed_or_text(job.ams_mapping2)},
                {"details", parsed_or_text(job.ams_mapping_info)},
                {"nozzles", parsed_or_text(job.nozzles_info)}
            }},
            {"options", {
                {"bed_type", job.bed_type},
                {"use_ams", job.use_ams},
                {"bed_leveling", job.bed_leveling},
                {"flow_calibration", job.flow_calibration},
                {"timelapse", job.timelapse}
            }}
        };

        {
            boost::nowide::ofstream stream(json_part.string(), std::ios::binary | std::ios::trunc);
            if (!stream) {
                fs::remove(file_path);
                return fail("Could not create the print job manifest.");
            }
            stream << manifest.dump(2) << '\n';
        }
        fs::rename(json_part, json_path, ec);
        if (ec) {
            fs::remove(json_part);
            fs::remove(file_path);
            return fail("Could not publish the print job manifest: " + ec.message());
        }

        if (!start_helper()) {
            fs::remove(json_path);
            fs::remove(file_path);
            return fail("Baleia Connect helper could not be started.");
        }
        BOOST_LOG_TRIVIAL(info) << "Baleia Connect job queued: " << job_id;
        return true;
    } catch (const std::exception &ex) {
        return fail(ex.what());
    }
#endif
}

void create_portable_backup()
{
    try {
        const fs::path root       = application_root();
        const fs::path live       = fs::path(Slic3r::data_dir());
        const fs::path expected   = root / "data_dir";
        const fs::path backup_dir = root / "Backups";

        if (live.empty() || !fs::exists(live) || !fs::exists(expected) ||
            !fs::equivalent(live, expected) || !has_live_data(live))
            return;

        fs::create_directories(backup_dir);
        fs::path final_path = backup_dir / utc_timestamp("%Y-%m-%d_%H-%M-%S");
        unsigned suffix = 1;
        while (fs::exists(final_path))
            final_path = backup_dir / (utc_timestamp("%Y-%m-%d_%H-%M-%S") + "_" + std::to_string(suffix++));
        const fs::path partial_path(final_path.string() + ".tmp");

        copy_tree(live, partial_path, true);
        write_marker(partial_path / backup_marker_name,
                     "Complete Baleia Orca profile backup created at " + utc_timestamp("%Y-%m-%dT%H:%M:%SZ") + "\n");
        fs::rename(partial_path, final_path);

        std::vector<fs::path> backups;
        for (fs::directory_iterator it(backup_dir), end; it != end; ++it) {
            if (fs::is_directory(it->path()) && fs::exists(it->path() / backup_marker_name))
                backups.emplace_back(it->path());
        }
        std::sort(backups.begin(), backups.end(), std::greater<fs::path>());
        while (backups.size() > backup_retention_count) {
            fs::remove_all(backups.back());
            backups.pop_back();
        }
    } catch (const std::exception &ex) {
        BOOST_LOG_TRIVIAL(error) << "Baleia portable profile backup failed: " << ex.what();
    }
}

} // namespace BaleiaConnect
} // namespace GUI
} // namespace Slic3r
