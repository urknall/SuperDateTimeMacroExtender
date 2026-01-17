# SuperDateTime Macro Extender

A Lyrion Music Server (LMS) plugin that extends SuperDateTime and CustomClock(Helper) applet/plugin with dynamic data from external JSON APIs.
Fetch real-time data (temperature, weather, power consumption, smart home status, etc.) and display it on your Squeezebox player's screen clock.

## Overview

SuperDateTime Macro Extender bridges the gap between SuperDateTime/Custom Clock plugins and external data sources. It fetches JSON data from configurable HTTP/HTTPS endpoints and makes the values accessible through custom macros that can be embedded in your clock display strings.

**Key Features:**
- 🌐 Fetch data from multiple JSON API endpoints
- 🔄 Automatic data caching (60-second default TTL)
- 📊 Support for various JSON formats (structured result arrays or simple key-value pairs)
- 🎯 Three lookup methods: by ID, index, or name
- 🔧 Built-in data transformation functions (round, truncate, ceil, floor, shorten)
- 🚀 Request queuing to prevent API hammering during frequent screen refreshes
- 🔌 Seamless integration with existing SuperDateTime macros via chaining
- 💾 Flexible caching strategies (server-wide or per-client)

## Installation

1. **Via LMS Web Interface (Recommended):**
   - Navigate to Settings → Plugins
   - Search for "SuperDateTime Macro Extender"
   - Click Install

2. **Manual Installation:**
   - Download the latest `.zip` release
   - Extract to your LMS plugins directory:
     - Linux: `/usr/share/squeezeboxserver/Plugins/`
     - Windows: `C:\Program Files\Squeezebox\server\Plugins\`
     - macOS: `/Library/Application Support/SqueezeCenter/Plugins/`
   - Restart Logitech Media Server

3. **Prerequisites:**
   - Lyrion Music Server 7.4 or higher
   - SuperDateTime or Custom Clock applet/plugin (for clock display functionality)

## Configuration

### Accessing Settings

Navigate to: **Settings → Plugins → SuperDateTime Macro Extender**

### API URL Configuration

1. **Adding JSON Endpoints:**
   - Enter one or more JSON API URLs in the configuration fields
   - Each URL must start with `http://` or `https://`
   - Multiple URLs are fetched sequentially and data is merged
   - Leave extra fields empty (they appear automatically)

2. **Multiple URL Behavior:**
   - All configured URLs are fetched in order
   - Data from all endpoints is merged into a single lookup table
   - If the same `id`, `idx`, or `Name` appears in multiple endpoints, the **later URL completely replaces** the earlier record (no field-level merging)

3. **URL Examples:**
   ```
   http://192.168.1.100:8080/json.htm?type=devices&used=true
   https://api.example.com/sensors/current
   http://homeassistant.local:8123/api/states
   ```

### Cache Strategy

Choose between two caching modes:

- **Server-Wide (Default):**
  - Single shared cache for all players
  - Reduces API load when multiple players display the same data
  - Recommended for most setups

- **Per-Client:**
  - Each player maintains its own cache
  - Each player fetches independently
  - Useful if different players need different data or if you have player-specific endpoints

## JSON Endpoint Format

### Standard Format (Recommended)

The plugin expects a JSON response with a `result` array containing objects:

```json
{
  "status": "OK",
  "timestamp": "2024-01-01T12:00:00+01:00",
  "result": [
    {
      "id": "TempOutside",
      "idx": 1,
      "Name": "Outside Temperature",
      "Value": 3.4,
      "ValueInt": 3,
      "Data": "3.4 °C",
      "Unit": "°C"
    },
    {
      "id": "PowerConsumption",
      "idx": 4,
      "Name": "Current Power",
      "Value": 2345.67,
      "Data": "2.3 kW"
    }
  ]
}
```

**Key Fields for Lookup:**
- `id` - String identifier (used with `~e...~` macros)
- `idx` - Numeric index (used with `~i...~` macros)  
- `Name` - Human-readable name (used with `~n...~` macros)

**Value Fields (customizable):**
- `Value` - Numeric value
- `ValueInt` - Integer value
- `Data` - Formatted string (e.g., "3.4 °C")
- `Unit` - Unit of measurement
- Any other custom fields you include

### Alternative Format: Raw Object

For simpler APIs, you can use a flat key-value structure:

```json
{
  "raw": {
    "1": 23.5,
    "2": "On",
    "TempA": 18.3,
    "Status": "OK"
  }
}
```

Or even simpler, place key-value pairs at the root level:

```json
{
  "1": 23.5,
  "2": "On",
  "TempA": 18.3,
  "Status": "OK"
}
```

**Raw Format Behavior:**
- Each key becomes a record
- `id` = key
- `Name` = "Key_" + key
- `idx` = key (if numeric)
- `Value` = value
- `Data` = stringified value

## Macro Syntax

Macros follow this pattern: `~<type><lookup>~<field>~[function]~[argument]~`

### Lookup Types

| Type | Syntax | Looks up by | Example |
|------|--------|-------------|---------|
| **e** | `~e<id>~` | `result[].id` | `~eTempOutside~Value~` |
| **i** | `~i<idx>~` | `result[].idx` | `~i1~Data~` |
| **n** | `~n<Name>~` | `result[].Name` | `~nOutside Temperature~Value~` |

**Important Notes:**
- `id` and `idx` lookups are exact matches
- `Name` lookups are **case-sensitive** and must match exactly
- Field names are case-insensitive with fallback matching

### Basic Macro Examples

```
~eTempOutside~Value~           → "3.4"
~eTempOutside~Data~            → "3.4 °C"
~eTempOutside~ValueInt~        → "3"
~i1~Data~                      → "3.4 °C"
~nCurrent Power~Value~         → "2345.67"
```

### Functions

Optional transformation functions can be applied to values:

#### Numeric Functions

**`round`** - Round to specified decimal places
```
~eTempOutside~Value~round~0~   → "3"    (round to integer)
~eTempOutside~Value~round~1~   → "3.4"  (1 decimal place)
~eTempOutside~Value~round~2~   → "3.40" (2 decimal places)
~ePower~Value~round~-2~        → "2300" (round to nearest hundred)
```

**`truncate`** - Cut decimal places toward zero (no rounding)
```
~eTempOutside~Value~truncate~0~  → "3"    (3.4 → 3, -3.7 → -3)
~eTempOutside~Value~truncate~1~  → "3.4"  (keep 1 decimal)
~ePower~Value~truncate~-2~       → "2300" (truncate to hundreds)
```

**`ceil`** - Round up to nearest integer
```
~eTempOutside~Value~ceil~      → "4"    (3.4 → 4)
~eNegative~Value~ceil~         → "-3"   (-3.7 → -3)
```

**`floor`** - Round down to nearest integer
```
~eTempOutside~Value~floor~     → "3"    (3.4 → 3)
~eNegative~Value~floor~        → "-4"   (-3.7 → -4)
```

#### String Functions

**`shorten`** - Truncate string to specified length
```
~eTempOutside~Data~shorten~5~  → "3.4 °"  (limit to 5 characters)
~eStatus~Data~shorten~10~      → "Everything " (first 10 chars)
```

### Function Behavior Notes

- Functions are **optional** - omit them to use raw values
- Non-numeric values passed to numeric functions are returned unchanged
- Decimal arguments are clamped to range [-12, 12] to prevent extreme calculations
- Unknown fields return nothing (macro is not replaced)
- Unknown functions cause the macro to end at the field, with remaining text treated as literal

**Example of unknown function:**
```
~eTempOutside~Value~unknownfunc~  → "3.4unknownfunc~"
```
The macro is replaced up to the field (`~eTempOutside~Value~` → `3.4`), and everything after (`unknownfunc~`) remains as literal text in the output.

## Complete Usage Examples

### Example 1: Simple Temperature Display

**JSON Endpoint:**
```json
{
  "result": [
    { "id": "TempOut", "idx": 1, "Value": 3.4, "Data": "3.4 °C" }
  ]
}
```

**SuperDateTime Format String:**
```
%H:%M Outside: ~eTempOut~Data~
```

**Display Output:**
```
14:35 Outside: 3.4 °C
```

### Example 2: Multiple Values with Rounding

**JSON Endpoint:**
```json
{
  "result": [
    { "id": "TempOut", "Value": 3.456 },
    { "id": "Humidity", "Value": 67.8 },
    { "id": "Power", "Value": 2345.67 }
  ]
}
```

**SuperDateTime Format String:**
```
%H:%M | ~eTempOut~Value~round~1~°C | ~eHumidity~Value~round~0~% | ~ePower~Value~round~-2~W
```

**Display Output:**
```
14:35 | 3.5°C | 68% | 2300W
```

### Example 3: Index-Based Lookup

**JSON Endpoint:**
```json
{
  "result": [
    { "idx": 1, "Data": "3.4 °C" },
    { "idx": 2, "Data": "Living Room" },
    { "idx": 3, "Data": "68%" }
  ]
}
```

**SuperDateTime Format String:**
```
%H:%M ~i1~ in ~i2~ Humidity: ~i3~
```

**Display Output:**
```
14:35 3.4 °C in Living Room Humidity: 68%
```

### Example 4: Raw Format with Simple Key-Value

**JSON Endpoint:**
```json
{
  "1": 23.5,
  "2": "On",
  "status": "OK"
}
```

**SuperDateTime Format String:**
```
Temp: ~e1~Value~°C Status: ~estatus~Value~
```

**Display Output:**
```
Temp: 23.5°C Status: OK
```

### Example 5: Combining with Standard SuperDateTime Macros

The plugin chains with SuperDateTime, so you can mix both macro types:

**SuperDateTime Format String:**
```
%H:%M:%S %A %d.%m.%Y | Outside: ~eTempOut~Value~round~1~°C | %o
```

**Display Output:**
```
14:35:42 Monday 15.01.2024 | Outside: 3.5°C | ♫ Artist - Title
```

## Advanced Configuration

### Cache Behavior

**Cache Duration:** 60 seconds (constant, not configurable)

**Cache Key Strategy:**
- **Server-Wide Mode:** Cache key is based on MD5 hash of joined URLs
  - All players with the same URL configuration share the cache
  - Only one API fetch occurs every 60 seconds regardless of player count
  
- **Per-Client Mode:** Cache key is based on client ID
  - Each player maintains its own cache
  - Each player fetches independently every 60 seconds

**Cache Limits:**
- Maximum cache entries: 100 clients
- When limit is reached: pruning occurs in two steps:
  1. First, all expired entries are removed
  2. If still at limit, the oldest 20% by expiry time are removed (entries closest to expiring)

**Stale Cache Fallback:**
- If all API fetches fail, stale cache data is used if less than 5 minutes old
- Prevents display disruption during temporary network issues

### Request Queue Management

To prevent overwhelming API endpoints during frequent screen refreshes:

- Maximum queue size per cache key: 50 requests
- Requests are processed sequentially per cache key
- If queue is full, new requests are dropped (with warning logged)
- Queued requests are served from cache or fresh data when available

### HTTP Request Timeouts

- Connection timeout: 10 seconds per URL
- Failed fetches are logged but don't block other URLs
- Sequential fetching means total wait time = timeout × number of URLs

## Troubleshooting

### Macros Not Being Replaced

**Check:**
1. **URL Configuration:**
   - Are URLs properly formatted with `http://` or `https://`?
   - Are the endpoints accessible from your LMS server?
   - Test URLs in a browser or with `curl`

2. **JSON Response Format:**
   - Does the response contain a `result` array or `raw` object?
   - Do records have `id`, `idx`, or `Name` fields?
   - Use browser DevTools or `curl -v` to inspect response

3. **Macro Syntax:**
   - Is the lookup key correct (case-sensitive for names)?
   - Does the field exist in the JSON response?
   - Are all delimiters (`~`) in place?

4. **Plugin Logs:**
   - Enable DEBUG logging for `plugin.superdatetimemacroextender`
   - Check LMS server logs for fetch errors or JSON parsing issues

### Data Not Updating

**Check:**
1. **Cache:** Data refreshes every 60 seconds - wait for cache to expire
2. **API Availability:** Check if the endpoint is responding
3. **Network Issues:** Verify LMS server can reach the API endpoints

### Performance Issues

**If experiencing slowdowns:**

1. **Reduce URL Count:** Each URL is fetched sequentially (10s timeout each)
2. **Optimize JSON Response:** Smaller payloads parse faster
3. **Check API Response Time:** Slow APIs delay all processing
4. **Consider Cache Mode:** Server-wide mode reduces API load

### Invalid URL Warnings

The settings page shows warnings for invalid URLs:
- URLs must start with `http://` or `https://`
- Invalid URLs are not saved
- Only valid URLs appear in the configuration after saving

## Technical Architecture

### Component Overview

**Plugin.pm**
- Main plugin logic and macro processing
- HTTP fetching with `Slim::Networking::SimpleAsyncHTTP`
- JSON parsing with `JSON::XS::VersionOneAndTwo` (backward compatible)
- Request queue management and caching
- Macro replacement engine

**Settings.pm**
- Web UI settings page handler
- URL validation and storage
- Dynamic form field generation

**strings.txt**
- English and German translations
- UI strings and help text

### Handler Chain

1. SuperDateTime/Custom Clock calls `sdtMacroString` dispatch
2. Plugin registers handler via `addDispatch` and saves previous handler
3. Plugin processes its macros (`~e...~`, `~i...~`, `~n...~`)
4. Plugin chains to previous handler (SuperDateTime) for standard macros
5. Result is returned to SuperDateTime/Custom Clock

### Data Flow

```
[JSON APIs] 
    ↓ (HTTP fetch, 10s timeout)
[JSON Parser] 
    ↓ (normalize to lookup tables)
[Cache] (60s TTL)
    ↓ (on cache hit or after fetch)
[Macro Processor]
    ↓ (find & replace macros)
[Chain to SuperDateTime]
    ↓ (process standard SDT macros)
[Return to Client]
```

### Compatibility

**Perl Version Compatibility:**
- Supports Perl 5.x versions from LMS 7.4+ (which may run older Perl versions)
- Includes fallback for `POSIX::round()` (not available before Perl 5.22) - ensures rounding works on all LMS versions
- Manual `uniq` implementation (List::Util::uniq added in Perl 5.26) - removes duplicate URLs on all systems

**LMS Version:**
- Minimum: 7.4
- Maximum: unlimited (tested up to latest versions)

## API Response Examples

### Domoticz Format

```json
{
  "ActTime": 1704110400,
  "ServerTime": "2024-01-01 12:00:00",
  "Sunrise": "08:20",
  "Sunset": "16:45",
  "result": [
    {
      "idx": 1,
      "id": "TempOutside",
      "Name": "Temperature Outside",
      "Type": "Temp",
      "SubType": "LaCrosse TX3",
      "Data": "3.4 °C",
      "Value": 3.4,
      "ValueInt": 3,
      "Unit": "°C",
      "LastUpdate": "2024-01-01 11:59:30"
    }
  ],
  "status": "OK",
  "title": "Devices"
}
```

### Home Assistant Format (adapted)

```json
{
  "result": [
    {
      "id": "sensor.outdoor_temp",
      "Name": "Outdoor Temperature",
      "Value": 3.4,
      "Data": "3.4°C",
      "Unit": "°C"
    },
    {
      "id": "sensor.power_consumption",
      "Name": "Power Consumption",
      "Value": 2345,
      "Data": "2.35 kW"
    }
  ]
}
```

### Custom IoT Device

```json
{
  "timestamp": "2024-01-01T12:00:00Z",
  "device_id": "esp32_001",
  "result": [
    { "idx": 1, "id": "temp", "Value": 22.5, "Data": "22.5°C" },
    { "idx": 2, "id": "humidity", "Value": 55, "Data": "55%" },
    { "idx": 3, "id": "pressure", "Value": 1013.25, "Data": "1013.25 hPa" }
  ]
}
```

## Development & Debugging

### Enable Debug Logging

1. Navigate to Settings → Logging in LMS web interface
2. Find "plugin.superdatetimemacroextender"
3. Set log level to DEBUG
4. Check server.log for detailed output

**Debug Output Includes:**
- JSON fetch attempts and results
- Macro replacements (before → after)
- Cache operations and pruning
- Request queue status

### Testing JSON Endpoints

**Command Line Testing:**
```bash
# Test endpoint availability
curl -v "http://192.168.1.100:8080/json.htm?type=devices"

# Pretty-print JSON response
curl -s "http://192.168.1.100:8080/json.htm?type=devices" | python -m json.tool

# Check response time
time curl -s "http://192.168.1.100:8080/json.htm?type=devices" > /dev/null
```

### Common Development Patterns

**Testing Macros:**
1. Start with a simple field lookup: `~eTEST~Data~`
2. Add rounding: `~eTEST~Value~round~1~`
3. Combine with SDT macros: `%H:%M ~eTEST~Data~`
4. Check logs for replacement confirmation

**Debugging Cache Issues:**
1. Enable DEBUG logging
2. Look for "Cached results for..." messages
3. Verify cache key matches expectation
4. Check cache size and pruning events

## Contributing

This plugin is open source. Contributions welcome!

**Repository:** https://github.com/urknall/SuperDateTimeMacroExtender

**Reporting Issues:**
- Include LMS version and plugin version
- Provide sample JSON endpoint response
- Include macro string that's not working
- Attach relevant log excerpts (with DEBUG enabled)

---

## Quick Reference Card

### Macro Types
```
~e<id>~<field>~             # Lookup by ID
~i<idx>~<field>~            # Lookup by index
~n<Name>~<field>~           # Lookup by name (case-sensitive)
```

### Functions
```
~e<id>~<field>~round~<decimals>~      # Round to N decimals
~e<id>~<field>~truncate~<decimals>~   # Truncate to N decimals
~e<id>~<field>~ceil~                  # Round up
~e<id>~<field>~floor~                 # Round down
~e<id>~<field>~shorten~<length>~      # Limit string length
```

### Required JSON Structure
```json
{
  "result": [
    { "id": "...", "idx": 1, "Name": "...", "<field>": "..." }
  ]
}
```

### Common Fields
- `Value` - numeric value
- `ValueInt` - integer value
- `Data` - formatted string
- `Unit` - unit of measurement
- Custom fields are supported
