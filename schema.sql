-- BiblioStatus Turso Database Schema

-- Libraries table (no historical versioning)
CREATE TABLE libraries (
    id INTEGER PRIMARY KEY,
    library_branch_name TEXT NOT NULL,
    lat REAL NOT NULL,
    lon REAL NOT NULL,
    city_name TEXT,
    library_url TEXT,
    library_phone TEXT,
    library_email TEXT,
    library_services TEXT,
    library_address TEXT,
    updated_at TEXT DEFAULT (datetime('now'))
);

-- Schedules table (with historical preservation)
CREATE TABLE schedules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    library_id INTEGER NOT NULL,
    date TEXT NOT NULL,
    from_time TEXT,
    to_time TEXT,
    status_label TEXT,
    inserted_at TEXT DEFAULT (datetime('now')),
    UNIQUE(library_id, date, from_time, to_time)  -- Prevent duplicates
);

-- Library Services junction table
-- Each library can have multiple services (normalized from comma-separated text)
CREATE TABLE library_services (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    library_id INTEGER NOT NULL,
    service_name TEXT NOT NULL,
    FOREIGN KEY (library_id) REFERENCES libraries(id),
    UNIQUE(library_id, service_name)  -- Prevent duplicate services per library
);

-- Indexes for performance
CREATE INDEX idx_schedules_library_date ON schedules(library_id, date);
CREATE INDEX idx_schedules_date ON schedules(date);
CREATE INDEX idx_libraries_id ON libraries(id);
CREATE INDEX idx_library_services_library_id ON library_services(library_id);
CREATE INDEX idx_library_services_service_name ON library_services(service_name);
