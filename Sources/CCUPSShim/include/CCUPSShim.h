#ifndef CCUPS_SHIM_PPD_H
#define CCUPS_SHIM_PPD_H

// CUPS's PPD API has been deprecated since macOS 10.8, which makes Swift treat it as unavailable.
// It is still the only way for a filter to learn which PPD choices apply to a job, so these thin
// wrappers call it from C, where deprecation is only a warning.

typedef struct brppd_s brppd_t;

/// Opens the PPD, marks its defaults, then marks the job's options (argv[5] of a CUPS filter). NULL on failure.
brppd_t *brppd_open(const char *ppd_path, const char *job_options);

/// The marked choice keyword for `option`, or NULL. Valid until `brppd_close`.
const char *brppd_marked_choice(brppd_t *ppd, const char *option);

/// The value of attribute `name` (any spec), or NULL. Valid until `brppd_close`.
const char *brppd_attribute(brppd_t *ppd, const char *name);

void brppd_close(brppd_t *ppd);

#endif
