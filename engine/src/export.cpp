// ScanForge Pro engine - STL, 3MF, OBJ and PLY export.
//
// 3MF files follow the 3MF Core Specification (units: millimetre) and are
// packaged in a standard OPC zip container, so they open directly in
// Bambu Studio, OrcaSlicer, PrusaSlicer and other slicers.
#include "sf_internal.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>

namespace sf {

namespace {

cv::Vec3f faceNormal(const cv::Vec3f& a, const cv::Vec3f& b, const cv::Vec3f& c) {
    cv::Vec3f n = (b - a).cross(c - a);
    float l = float(cv::norm(n));
    return l > 0 ? n / l : cv::Vec3f(0, 0, 1);
}

// ---- minimal zip writer (stored entries) -----------------------------------
uint32_t crcTable[256];
bool crcInit = false;

uint32_t crc32(const std::string& data) {
    if (!crcInit) {
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int k = 0; k < 8; ++k) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            crcTable[i] = c;
        }
        crcInit = true;
    }
    uint32_t c = 0xFFFFFFFFu;
    for (unsigned char ch : data) c = crcTable[(c ^ ch) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

void put16(std::string& s, uint16_t v) { s.push_back(char(v & 0xFF)); s.push_back(char(v >> 8)); }
void put32(std::string& s, uint32_t v) { for (int k = 0; k < 4; ++k) s.push_back(char((v >> (8 * k)) & 0xFF)); }

struct ZipEntry {
    std::string name;
    std::string data;
};

bool writeZip(const std::string& path, const std::vector<ZipEntry>& entries) {
    std::ofstream f(path, std::ios::binary);
    if (!f) return false;
    const uint16_t dosTime = 0;
    const uint16_t dosDate = uint16_t(((2026 - 1980) << 9) | (1 << 5) | 1);
    std::string central;
    uint32_t offset = 0;
    for (const auto& e : entries) {
        uint32_t crc = crc32(e.data);
        std::string h;
        put32(h, 0x04034b50);
        put16(h, 20); put16(h, 0); put16(h, 0);
        put16(h, dosTime); put16(h, dosDate);
        put32(h, crc);
        put32(h, uint32_t(e.data.size())); put32(h, uint32_t(e.data.size()));
        put16(h, uint16_t(e.name.size())); put16(h, 0);
        h += e.name;
        f.write(h.data(), h.size());
        f.write(e.data.data(), e.data.size());

        put32(central, 0x02014b50);
        put16(central, 20); put16(central, 20); put16(central, 0); put16(central, 0);
        put16(central, dosTime); put16(central, dosDate);
        put32(central, crc);
        put32(central, uint32_t(e.data.size())); put32(central, uint32_t(e.data.size()));
        put16(central, uint16_t(e.name.size()));
        put16(central, 0); put16(central, 0); put16(central, 0); put16(central, 0);
        put32(central, 0);
        put32(central, offset);
        central += e.name;
        offset += uint32_t(h.size() + e.data.size());
    }
    std::string end;
    put32(end, 0x06054b50);
    put16(end, 0); put16(end, 0);
    put16(end, uint16_t(entries.size())); put16(end, uint16_t(entries.size()));
    put32(end, uint32_t(central.size()));
    put32(end, offset);
    put16(end, 0);
    f.write(central.data(), central.size());
    f.write(end.data(), end.size());
    return bool(f);
}

std::string xmlEscape(const std::string& s) {
    std::string o;
    for (char c : s) {
        switch (c) {
            case '&': o += "&amp;"; break;
            case '<': o += "&lt;"; break;
            case '>': o += "&gt;"; break;
            case '"': o += "&quot;"; break;
            case '\'': o += "&apos;"; break;
            default: o.push_back(c);
        }
    }
    return o;
}

}  // namespace

bool exportSTL(const std::string& path, const Mesh& m, float scale, const std::string& name) {
    std::ofstream f(path, std::ios::binary);
    if (!f) return false;
    char header[80] = {0};
    std::snprintf(header, sizeof(header), "ScanForge Pro - %s (mm)", name.c_str());
    f.write(header, 80);
    uint32_t n = uint32_t(m.f.size());
    f.write(reinterpret_cast<const char*>(&n), 4);
    for (const auto& t : m.f) {
        cv::Vec3f a = m.v[t[0]] * scale, b = m.v[t[1]] * scale, c = m.v[t[2]] * scale;
        cv::Vec3f nn = faceNormal(a, b, c);
        float buf[12] = {nn[0], nn[1], nn[2], a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2]};
        f.write(reinterpret_cast<const char*>(buf), 48);
        uint16_t attr = 0;
        f.write(reinterpret_cast<const char*>(&attr), 2);
    }
    return bool(f);
}

bool export3MF(const std::string& path, const Mesh& m, float scale, float bedX, float bedY,
               const std::string& name) {
    cv::Vec3f mn, mx;
    m.bounds(mn, mx);
    mn *= scale;
    mx *= scale;
    float tx = bedX * 0.5f - 0.5f * (mn[0] + mx[0]);
    float ty = bedY * 0.5f - 0.5f * (mn[1] + mx[1]);
    float tz = -mn[2];

    std::string model;
    model.reserve(m.v.size() * 64 + m.f.size() * 48 + 1024);
    model +=
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        "<model unit=\"millimeter\" xml:lang=\"en-US\" "
        "xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\">\n"
        " <metadata name=\"Application\">ScanForge Pro</metadata>\n"
        " <metadata name=\"Title\">" + xmlEscape(name) + "</metadata>\n"
        " <resources>\n"
        "  <object id=\"1\" type=\"model\" name=\"" + xmlEscape(name) + "\">\n"
        "   <mesh>\n    <vertices>\n";
    char buf[160];
    for (const auto& p : m.v) {
        int n = std::snprintf(buf, sizeof(buf), "     <vertex x=\"%.4f\" y=\"%.4f\" z=\"%.4f\"/>\n",
                              p[0] * scale, p[1] * scale, p[2] * scale);
        model.append(buf, n);
    }
    model += "    </vertices>\n    <triangles>\n";
    for (const auto& t : m.f) {
        int n = std::snprintf(buf, sizeof(buf), "     <triangle v1=\"%d\" v2=\"%d\" v3=\"%d\"/>\n", t[0], t[1], t[2]);
        model.append(buf, n);
    }
    model += "    </triangles>\n   </mesh>\n  </object>\n </resources>\n <build>\n";
    std::snprintf(buf, sizeof(buf), "  <item objectid=\"1\" transform=\"1 0 0 0 1 0 0 0 1 %.4f %.4f %.4f\"/>\n",
                  tx, ty, tz);
    model += buf;
    model += " </build>\n</model>\n";

    std::vector<ZipEntry> entries;
    entries.push_back({"[Content_Types].xml",
                       "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                       "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
                       "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
                       "<Default Extension=\"model\" ContentType=\"application/vnd.ms-package.3dmanufacturing-3dmodel+xml\"/>"
                       "</Types>\n"});
    entries.push_back({"_rels/.rels",
                       "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                       "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                       "<Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" "
                       "Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/>"
                       "</Relationships>\n"});
    entries.push_back({"3D/3dmodel.model", std::move(model)});
    return writeZip(path, entries);
}

bool exportOBJ(const std::string& path, const Mesh& m, float scale) {
    std::ofstream f(path);
    if (!f) return false;
    f << "# ScanForge Pro (millimetres, vertex colours)\n";
    char buf[160];
    for (size_t i = 0; i < m.v.size(); ++i) {
        const auto& p = m.v[i];
        cv::Vec3b c = i < m.c.size() ? m.c[i] : cv::Vec3b(180, 180, 180);
        std::snprintf(buf, sizeof(buf), "v %.4f %.4f %.4f %.4f %.4f %.4f\n", p[0] * scale, p[1] * scale,
                      p[2] * scale, c[0] / 255.0, c[1] / 255.0, c[2] / 255.0);
        f << buf;
    }
    for (const auto& t : m.f) f << "f " << t[0] + 1 << ' ' << t[1] + 1 << ' ' << t[2] + 1 << '\n';
    return bool(f);
}

bool exportPLY(const std::string& path, const Mesh& m, float scale) {
    Mesh s = m;
    for (auto& p : s.v) p *= scale;
    return savePLY(path, s);
}

}  // namespace sf
