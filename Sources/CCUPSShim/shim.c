#include "CCUPSShim.h"

#include <cups/cups.h>
#include <cups/ppd.h>
#include <stdlib.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

struct brppd_s {
    ppd_file_t *ppd;
};

brppd_t *brppd_open(const char *ppd_path, const char *job_options) {
    if (!ppd_path) return NULL;

    ppd_file_t *ppd = ppdOpenFile(ppd_path);
    if (!ppd) return NULL;

    ppdMarkDefaults(ppd);

    cups_option_t *options = NULL;
    int count = cupsParseOptions(job_options ? job_options : "", 0, &options);
    cupsMarkOptions(ppd, count, options);
    cupsFreeOptions(count, options);

    brppd_t *handle = malloc(sizeof(*handle));
    if (!handle) {
        ppdClose(ppd);
        return NULL;
    }
    handle->ppd = ppd;
    return handle;
}

const char *brppd_marked_choice(brppd_t *handle, const char *option) {
    ppd_choice_t *choice = ppdFindMarkedChoice(handle->ppd, option);
    return choice ? choice->choice : NULL;
}

const char *brppd_attribute(brppd_t *handle, const char *name) {
    ppd_attr_t *attr = ppdFindAttr(handle->ppd, name, NULL);
    return attr ? attr->value : NULL;
}

void brppd_close(brppd_t *handle) {
    if (!handle) return;
    ppdClose(handle->ppd);
    free(handle);
}
