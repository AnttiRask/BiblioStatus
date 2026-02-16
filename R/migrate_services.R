#!/usr/bin/env Rscript
# Migrate existing library_services from comma-separated to normalized table

library(dplyr)
library(stringr)
library(here)

source(here("R/turso.R"))

cat("\n=== Library Services Migration ===\n")
cat("Migrating from comma-separated to normalized table...\n\n")

# 1. Fetch current libraries with services
cat("Fetching current libraries with services from Turso...\n")
libraries <- turso_query("SELECT id, library_services FROM libraries")

cat(sprintf("Found %d libraries\n", nrow(libraries)))

# 2. Split comma-separated services into rows
cat("Splitting services into normalized format...\n")
library_services <- libraries %>%
  filter(!is.na(library_services), library_services != "") %>%
  mutate(services_list = str_split(library_services, ",\\s*")) %>%
  tidyr::unnest(services_list) %>%
  select(library_id = id, service_name = services_list) %>%
  distinct()

cat(sprintf("Found %d unique library-service combinations\n", nrow(library_services)))
cat(sprintf("Found %d unique services\n", n_distinct(library_services$service_name)))

# 3. Clear existing data (if any)
cat("\nClearing existing data from library_services table...\n")
turso_execute("DELETE FROM library_services")

# 4. Insert into new table
cat("Inserting normalized services into Turso...\n")
for (i in 1:nrow(library_services)) {
  svc <- library_services[i, ]
  turso_execute(
    "INSERT INTO library_services (library_id, service_name) VALUES (?, ?)",
    list(svc$library_id, svc$service_name)
  )

  if (i %% 100 == 0) {
    cat(sprintf("  Inserted %d/%d records (%d%%)...\n",
                i, nrow(library_services), round(100 * i / nrow(library_services))))
  }
}

cat(sprintf("  ✓ Inserted %d/%d records (100%%)\n", nrow(library_services), nrow(library_services)))

# 5. Verify
cat("\nVerifying migration...\n")
summary <- turso_query("
  SELECT
    COUNT(*) as total_services,
    COUNT(DISTINCT library_id) as libraries_with_services,
    COUNT(DISTINCT service_name) as unique_services
  FROM library_services
")

cat("\nMigration Summary:\n")
cat(sprintf("  Total service records: %d\n", summary$total_services))
cat(sprintf("  Libraries with services: %d\n", summary$libraries_with_services))
cat(sprintf("  Unique services: %d\n", summary$unique_services))

cat("\n✓ Migration complete!\n\n")
