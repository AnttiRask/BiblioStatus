# Library Services Normalization & Enhancement Plan

## Overview

This document outlines the plan to normalize the library services data structure and add enhanced search and filtering capabilities to the BiblioStatus application.

## Current State

- Services stored as comma-separated TEXT in `libraries.library_services` column
- Example: "E-kirjasto (e-kirjat, äänikirjat, digilehdet), Tietokoneet"
- Displayed as plain text in sidebar when library is selected
- No filtering or search capabilities

## Goals

1. **Normalize database schema** - Create separate `library_services` table
2. **Add library text search** - Find libraries by name, auto-switch city
3. **Add service filtering** - Filter map by selected service
4. **Enhance service display** - Show services as visual badges
5. **Add statistics dashboard** - Visualize service distribution with city filtering
6. **Add service search** - Autocomplete search for services

## Database Schema Changes

### New Table: library_services

```sql
CREATE TABLE library_services (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    library_id INTEGER NOT NULL,
    service_name TEXT NOT NULL,
    FOREIGN KEY (library_id) REFERENCES libraries(id),
    UNIQUE(library_id, service_name)
);

CREATE INDEX idx_library_services_library_id ON library_services(library_id);
CREATE INDEX idx_library_services_service_name ON library_services(service_name);
```

### Migration Strategy

1. Create new table in both Turso and SQLite
2. Migrate existing comma-separated data to normalized rows
3. Update data fetching logic to populate new table
4. Update app to read from new table
5. Keep old column temporarily for safety (can be removed later)

## Implementation Phases

### Phase 1-6: Core Normalization

See detailed implementation in plan file for:
- Schema creation
- Data migration script
- Fetch logic updates
- App function updates
- Testing

### Phase 7: Library Text Search

**UI Addition:**
```r
textInput(
  "library_search",
  "Search Libraries:",
  placeholder = "Type library name...",
  value = ""
)
```

**Features:**
- Type-ahead search (minimum 3 characters)
- Automatically switches to matched library's city
- Zooms map to library location
- Case-insensitive matching

### Phase 8: Service-Based Filtering

**UI Addition:**
```r
selectInput(
  "service_filter",
  "Filter by Service:",
  choices = c("All Services" = "", ...),
  selected = ""
)
```

**Features:**
- Dropdown populated with all unique services
- Filters map markers to only show libraries offering selected service
- "All Services" option clears filter
- Works in conjunction with city filter

### Phase 9: Enhanced Service Display

**Current:** Plain comma-separated text

**New:** Visual badges with styling
```r
span(
  service_name,
  class = "badge badge-service",
  style = "background: #e3f2fd; color: #1976d2; padding: 4px 8px; ..."
)
```

**Benefits:**
- More visually appealing
- Easier to scan
- Professional appearance

### Phase 10: Service Statistics Dashboard

**New Tab: "Service Statistics"**

Components:
1. **City Filter Dropdown** - Filter statistics by city
2. **Bar Chart** - Top 15 services by library count
3. **Data Table** - All services with counts, sortable/searchable

**Features:**
- Visualize which services are most common
- Compare across cities or view all
- Interactive ggplot2 bar chart
- DT data table with full data

### Phase 11: Service Search Autocomplete

**UI Addition:**
```r
searchInput(
  inputId = "service_search",
  label = "Search for a service:",
  placeholder = "Type to search..."
)
```

**Features:**
- Auto-suggests matching services as you type
- Automatically selects first match in service filter
- Uses shinyWidgets for enhanced UX

## Files to Create

- `R/migrate_services.R` - One-time migration script
- `app/modules/service_stats.R` - Service statistics module
- `SERVICE_NORMALIZATION_PLAN.md` - This file

## Files to Modify

- `schema.sql` - Add library_services table definition
- `fetch_library_data.R` - Extract and write services to new table
- `app/www/functions.R` - Add fetch_library_services() function
- `app/ui.R` - Add search inputs, service filter, statistics tab
- `app/server.R` - Add all new functionality (search, filter, stats)
- `renv.lock` - Add shinyWidgets dependency

## Dependencies to Add

```r
renv::install("shinyWidgets")
renv::snapshot()
```

## Testing Checklist

### Core Functionality
- [ ] library_services table created in Turso
- [ ] library_services table created in SQLite
- [ ] Migration script runs without errors
- [ ] All existing services migrated correctly
- [ ] Weekly library update populates new table
- [ ] App displays services (no regression)

### Library Text Search
- [ ] Search finds libraries by partial name
- [ ] City automatically switches to matched library
- [ ] Map zooms to library location
- [ ] Search is case-insensitive
- [ ] Works with 3+ characters

### Service Filter
- [ ] Dropdown populates with all services
- [ ] Map filters to selected service
- [ ] "All Services" clears filter
- [ ] Works with city filter
- [ ] Count updates correctly

### Service Display
- [ ] Badges display with proper styling
- [ ] Multiple badges wrap correctly
- [ ] "No services" message shows when appropriate
- [ ] Badges are readable and attractive

### Statistics Dashboard
- [ ] Tab loads without errors
- [ ] City filter populates correctly
- [ ] Bar chart displays top 15 services
- [ ] Chart updates when city changes
- [ ] Data table shows all services
- [ ] Table is sortable and searchable
- [ ] "All Cities" option works

### Service Search
- [ ] Search input accepts text
- [ ] Auto-suggests matching services
- [ ] Selecting service filters map
- [ ] Clear button resets search

## Deployment Strategy

1. **Local Testing** - Test all features on local machine
2. **Migration** - Run migration script on production Turso database
3. **Deploy Code** - Push code changes to GitHub
4. **GitHub Actions** - Verify weekly update runs successfully
5. **Production Test** - Test all features on deployed Cloud Run app
6. **Monitor** - Watch logs for 24-48 hours

## Rollback Plan

**If issues arise:**
1. Revert code changes via Git
2. Old `library_services` column still exists as backup
3. Drop new `library_services` table if needed
4. Redeploy previous version

**Data safety:**
- No data is deleted during migration
- Old column remains intact
- SQLite backup maintains both formats
- Can regenerate from API anytime

## Benefits Summary

**For Users:**
- Fast library search by name
- Filter libraries by services offered
- Beautiful visual service badges
- Service statistics and insights
- City-specific service analysis

**For Developers:**
- Proper database normalization (3NF)
- Efficient querying capabilities
- Clean separation of concerns
- Modular code organization
- Foundation for future enhancements

**For Data Quality:**
- No duplicate service names
- Consistent formatting
- Easy to identify popular services
- Simpler data maintenance

## Timeline

**Estimated: 5-6 hours**
- Phase 1-3: Schema + migration (1.5 hours)
- Phase 4-6: Core app updates (1 hour)
- Phase 7-9: Search + filtering (1.5 hours)
- Phase 10: Statistics dashboard (1 hour)
- Phase 11: Service search (30 min)
- Testing + deployment (1 hour)

## Success Metrics

- Zero data loss during migration
- All features working on production
- No performance degradation
- Positive user feedback
- Clean code review

---

## Implementation Status

**Status:** ✅ **Implementation Complete** (Phases 1-10)

**Completed Features:**
- ✅ Phase 1-2: Database schema normalization (Turso + SQLite)
- ✅ Phase 3: Data migration (11,722 service records, 247 unique services)
- ✅ Phase 4-6: Core app updates and testing
- ✅ Phase 7: Library text search with auto-city switching
- ✅ Phase 8: Service-based filtering
- ✅ Phase 9: Visual service badges
- ✅ Phase 10: Service statistics dashboard with city filtering

**Skipped:**
- Phase 11: Service search autocomplete (shinyWidgets) - Can be added later if needed

**Ready for:** Production deployment

**Migration Results:**
- Total service records: 11,722
- Libraries with services: 575
- Unique services: 247
- Zero data loss ✅

**Implementation Date:** February 2026
