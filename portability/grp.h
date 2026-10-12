#pragma once
#include_next <grp.h>

#ifdef NEED_FGETGRENT
#include <stdio.h>
struct group *fgetgrent(FILE *stream);
#endif
