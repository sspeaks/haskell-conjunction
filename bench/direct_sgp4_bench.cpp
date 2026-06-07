#include "SGP4.h"

#include <cstddef>
#include <ctime>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace
{

const std::size_t default_iterations = 10000;
const char *default_workload_path = "bench/workload.tsv";

struct WorkItem
{
    std::string name;
    std::string line1;
    std::string line2;
};

struct Workload
{
    std::vector<double> times;
    std::vector<WorkItem> items;
};

struct InitializedItem
{
    std::string name;
    elsetrec satrec;
};

enum class BenchmarkMode
{
    EndToEnd,
    PropagationOnly
};

std::string trim(const std::string &input)
{
    const std::string whitespace = " \t\n\r\f\v";
    const std::size_t first = input.find_first_not_of(whitespace);
    if (first == std::string::npos)
        return "";
    const std::size_t last = input.find_last_not_of(whitespace);
    return input.substr(first, last - first + 1);
}

bool starts_with(const std::string &value, const std::string &prefix)
{
    return value.compare(0, prefix.size(), prefix) == 0;
}

std::vector<std::string> split_tabs(const std::string &input)
{
    std::vector<std::string> fields;
    std::size_t start = 0;
    while (true)
    {
        const std::size_t tab = input.find('\t', start);
        if (tab == std::string::npos)
        {
            fields.push_back(input.substr(start));
            return fields;
        }
        fields.push_back(input.substr(start, tab - start));
        start = tab + 1;
    }
}

std::vector<double> parse_times_line(const std::string &line)
{
    std::istringstream stream(line);
    std::string hash;
    std::string label;
    stream >> hash >> label;
    if (hash != "#" || label != "times_minutes")
        throw std::runtime_error("invalid times header: " + line);

    std::vector<double> times;
    double value = 0.0;
    while (stream >> value)
        times.push_back(value);

    if (times.empty())
        throw std::runtime_error("workload has no propagation times");

    return times;
}

WorkItem parse_work_item(const std::string &line)
{
    const std::vector<std::string> fields = split_tabs(line);
    if (fields.size() != 3)
        throw std::runtime_error("invalid workload row, expected name<TAB>line1<TAB>line2: " + line);
    if (fields[0].empty())
        throw std::runtime_error("workload row has an empty satellite name");

    return WorkItem{fields[0], fields[1], fields[2]};
}

Workload read_workload(const std::string &path)
{
    std::ifstream input(path.c_str());
    if (!input)
        throw std::runtime_error("failed to open workload: " + path);

    Workload workload;
    bool saw_times = false;
    std::string line;
    while (std::getline(input, line))
    {
        const std::string stripped = trim(line);
        if (stripped.empty())
            continue;
        if (starts_with(stripped, "# times_minutes"))
        {
            if (saw_times)
                throw std::runtime_error("workload has multiple times headers");
            workload.times = parse_times_line(stripped);
            saw_times = true;
            continue;
        }
        if (starts_with(stripped, "#"))
            continue;

        workload.items.push_back(parse_work_item(stripped));
    }

    if (!saw_times)
        throw std::runtime_error("workload is missing '# times_minutes ...' header");
    if (workload.items.empty())
        throw std::runtime_error("workload has no TLE rows");

    return workload;
}

std::size_t parse_iterations(const char *raw)
{
    std::istringstream stream(raw);
    std::size_t iterations = 0;
    stream >> iterations;
    if (!stream || !stream.eof() || iterations == 0)
        throw std::runtime_error(std::string("invalid positive iteration count: ") + raw);
    return iterations;
}

BenchmarkMode parse_mode(const char *raw)
{
    const std::string mode(raw);
    if (mode == "end-to-end")
        return BenchmarkMode::EndToEnd;
    if (mode == "propagation-only")
        return BenchmarkMode::PropagationOnly;
    throw std::runtime_error("invalid benchmark mode: " + mode);
}

void copy_tle_line(char dest[130], const std::string &src)
{
    if (src.size() < 69 || src.size() >= 130)
        throw std::runtime_error("invalid TLE line length");

    std::memset(dest, 0, 130);
    std::memcpy(dest, src.c_str(), src.size());
}

elsetrec initialize_item(const WorkItem &item)
{
    char line1[130];
    char line2[130];
    copy_tle_line(line1, item.line1);
    copy_tle_line(line2, item.line2);

    elsetrec satrec;
    std::memset(&satrec, 0, sizeof(satrec));

    double startmfe = 0.0;
    double stopmfe = 0.0;
    double deltamin = 0.0;
    SGP4Funcs::twoline2rv(
        line1,
        line2,
        'c',
        'm',
        'a',
        wgs72,
        startmfe,
        stopmfe,
        deltamin,
        satrec);

    if (satrec.error != 0)
        throw std::runtime_error("failed to initialize " + item.name + ": " + std::to_string(satrec.error));

    return satrec;
}

std::vector<InitializedItem> initialize_workload(const Workload &workload)
{
    std::vector<InitializedItem> initialized;
    initialized.reserve(workload.items.size());
    for (const WorkItem &item : workload.items)
        initialized.push_back(InitializedItem{item.name, initialize_item(item)});
    return initialized;
}

double state_checksum(const double r[3], const double v[3], double tsince)
{
    return r[0] * 1.0e-3
           + r[1] * 2.0e-3
           + r[2] * 3.0e-3
           + v[0] * 5.0e-2
           + v[1] * 7.0e-2
           + v[2] * 11.0e-2
           + tsince * 1.0e-6;
}

double propagate_item(const std::string &name, elsetrec &satrec, const std::vector<double> &times)
{
    double checksum = 0.0;

    for (double tsince : times)
    {
        double r[3] = {0.0, 0.0, 0.0};
        double v[3] = {0.0, 0.0, 0.0};
        const bool ok = SGP4Funcs::sgp4(satrec, tsince, r, v);
        if (!ok || satrec.error != 0)
            throw std::runtime_error("failed to propagate " + name + ": " + std::to_string(satrec.error));
        checksum += state_checksum(r, v, tsince);
    }

    return checksum;
}

double run_end_to_end_once(const Workload &workload)
{
    double checksum = 0.0;
    for (const WorkItem &item : workload.items)
    {
        elsetrec satrec = initialize_item(item);
        checksum += propagate_item(item.name, satrec, workload.times);
    }
    return checksum;
}

double run_propagation_only_once(const std::vector<double> &times, std::vector<InitializedItem> &items)
{
    double checksum = 0.0;
    for (InitializedItem &item : items)
        checksum += propagate_item(item.name, item.satrec, times);
    return checksum;
}

double run_iterations(std::size_t iterations, const Workload &workload, BenchmarkMode mode)
{
    double checksum = 0.0;
    if (mode == BenchmarkMode::EndToEnd)
    {
        for (std::size_t i = 0; i < iterations; ++i)
            checksum += run_end_to_end_once(workload);
    }
    else
    {
        std::vector<InitializedItem> initialized = initialize_workload(workload);
        for (std::size_t i = 0; i < iterations; ++i)
            checksum += run_propagation_only_once(workload.times, initialized);
    }
    return checksum;
}

const char *mode_name(BenchmarkMode mode)
{
    switch (mode)
    {
    case BenchmarkMode::EndToEnd:
        return "end-to-end";
    case BenchmarkMode::PropagationOnly:
        return "propagation-only";
    }

    return "unknown";
}

void print_report(
    BenchmarkMode mode,
    std::size_t iterations,
    const Workload &workload,
    double checksum,
    double elapsed_seconds)
{
    const std::size_t state_vectors = iterations * workload.items.size() * workload.times.size();
    const double ns_per_iteration = elapsed_seconds * 1.0e9 / static_cast<double>(iterations);
    const double ns_per_state_vector = elapsed_seconds * 1.0e9 / static_cast<double>(state_vectors);

    std::cout << std::fixed << std::setprecision(12);
    std::cout << "benchmark=direct-cpp-" << mode_name(mode) << "\n";
    std::cout << "iterations=" << iterations << "\n";
    std::cout << "tle_count=" << workload.items.size() << "\n";
    std::cout << "times_per_tle=" << workload.times.size() << "\n";
    std::cout << "state_vectors=" << state_vectors << "\n";
    std::cout << "checksum=" << checksum << "\n";
    std::cout << "cpu_seconds=" << std::setprecision(9) << elapsed_seconds << "\n";
    std::cout << "ns_per_iteration=" << std::setprecision(3) << ns_per_iteration << "\n";
    std::cout << "ns_per_state_vector=" << ns_per_state_vector << "\n";
}

} // namespace

int main(int argc, char **argv)
{
    try
    {
        if (argc > 4)
            throw std::runtime_error("usage: direct-sgp4-bench [iterations] [workload-path] [end-to-end|propagation-only]");

        const std::size_t iterations = argc >= 2 ? parse_iterations(argv[1]) : default_iterations;
        const std::string workload_path = argc >= 3 ? argv[2] : default_workload_path;
        const BenchmarkMode mode = argc >= 4 ? parse_mode(argv[3]) : BenchmarkMode::EndToEnd;
        const Workload workload = read_workload(workload_path);

        (void)run_iterations(1, workload, mode);
        const std::clock_t start = std::clock();
        const double checksum = run_iterations(iterations, workload, mode);
        const std::clock_t end = std::clock();

        const double elapsed_seconds = static_cast<double>(end - start) / static_cast<double>(CLOCKS_PER_SEC);
        print_report(mode, iterations, workload, checksum, elapsed_seconds);
    }
    catch (const std::exception &err)
    {
        std::cerr << "direct-sgp4-bench: " << err.what() << "\n";
        return 1;
    }

    return 0;
}
