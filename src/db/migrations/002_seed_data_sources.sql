-- =============================================================================
-- Global source catalogue with licence and permitted-use metadata.
-- Per-workspace enable/config lives in workspace_sources.
-- AI models and prices are NOT seeded here: they must come from the providers'
-- current price lists (the frontend's figures are demo values).
-- =============================================================================
INSERT INTO data_sources
  (id, name, kind, description, lead_types, incremental, update_cadence, coverage_note, rate_limit, available,
   license_name, license_url, attribution, commercial_use, redistribution, license_notes)
VALUES
  ('osm', 'OpenStreetMap (Geofabrik extracts)', 'Open dataset',
   'Business points of interest from regional .osm.pbf extracts: names, categories, addresses, websites and phones where mapped.',
   '{business}', true, 'Daily extracts; re-imported only when the extract changes',
   'Coverage is uneven. A mapped place is not proof the business still operates.',
   'File download; no API calls', true,
   'ODbL 1.0', 'https://www.openstreetmap.org/copyright', '© OpenStreetMap contributors', 'conditional', 'conditional',
   'Share-alike applies to derived databases that are publicly distributed. Review before redistributing exports.'),

  ('wikidata', 'Wikidata', 'Open dataset',
   'Targeted SPARQL queries for organizations: official websites, industries, headquarters, identifiers.',
   '{business}', true, 'Query on demand per project',
   'Strong for notable organizations; thin for small businesses.',
   'Query service fair-use limits', true,
   'CC0 1.0', 'https://www.wikidata.org/wiki/Wikidata:Licensing', 'Wikidata', 'permitted', 'permitted',
   'Structured data is public domain.'),

  ('gleif', 'GLEIF LEI records', 'Registry API',
   'Legal entity identifiers for discovery and legal-name validation.',
   '{business}', true, 'Delta files three times daily',
   'Only entities that registered an LEI.',
   '60 requests / minute', true,
   'CC0 1.0', 'https://www.gleif.org/en/meta/lei-data-terms-of-use', 'GLEIF', 'permitted', 'permitted',
   'Free to use and redistribute.'),

  ('companies_house', 'Companies House', 'Registry API',
   'UK company register: status, SIC codes, registered office and officers.',
   '{business,professional}', true, 'Streaming API for changes',
   'UK-registered companies only. Officer data is personal data under UK GDPR.',
   '600 requests / 5 minutes', true,
   'Open Government Licence v3', 'https://developer.company-information.service.gov.uk/',
   'Contains public sector information licensed under the OGL v3.0', 'conditional', 'conditional',
   'Personal data about officers needs a lawful basis to process.'),

  ('sec_edgar', 'SEC EDGAR', 'Registry API',
   'US public-company filings and officers. Not a small-business directory.',
   '{business,professional}', true, 'Nightly index',
   'US public registrants only.',
   '10 requests / second', true,
   'US public domain', 'https://www.sec.gov/edgar/sec-api-documentation',
   'U.S. Securities and Exchange Commission', 'permitted', 'permitted',
   'Declare a User-Agent; 10 requests/second maximum.'),

  ('company_websites', 'Company websites', 'Web research',
   'Up to five relevant pages per company (home, about, services, contact, team), fetched politely and hashed for change detection.',
   '{business,professional}', true, 'Re-checked each scheduled run; AI only when the page hash changes',
   'Robots rules, crawl delays and site terms are respected. No logins, paywalls or CAPTCHAs.',
   '1 request / 2s per domain, 4 domains in parallel', true,
   'Per-site terms', '', 'Source URL kept on every field', 'review_required', 'restricted',
   'Publicly visible is not automatically reusable. Facts are stored with their page URL.'),

  ('csv_upload', 'CSV upload', 'Customer upload',
   'Your own lists, mapped to LeadForge fields, validated and deduplicated on import.',
   '{business,professional}', false, 'On upload',
   'You confirm you have the right to process uploaded data.',
   '50 MB per file', true,
   'Customer provided', '', 'Uploaded by workspace', 'permitted', 'restricted',
   'Kept private to this workspace.'),

  ('common_crawl', 'Common Crawl', 'Web corpus',
   'Large-scale web discovery from crawl archives. Planned for a later phase.',
   '{business}', true, 'Monthly crawl releases',
   'Not active in this version.',
   '—', false,
   'Common Crawl terms of use', 'https://commoncrawl.org/terms-of-use', 'Common Crawl', 'review_required', 'review_required',
   'Underlying page content keeps its own copyright.')
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name, kind = EXCLUDED.kind, description = EXCLUDED.description,
  lead_types = EXCLUDED.lead_types, incremental = EXCLUDED.incremental,
  update_cadence = EXCLUDED.update_cadence, coverage_note = EXCLUDED.coverage_note,
  rate_limit = EXCLUDED.rate_limit, available = EXCLUDED.available,
  license_name = EXCLUDED.license_name, license_url = EXCLUDED.license_url,
  attribution = EXCLUDED.attribution, commercial_use = EXCLUDED.commercial_use,
  redistribution = EXCLUDED.redistribution, license_notes = EXCLUDED.license_notes;
