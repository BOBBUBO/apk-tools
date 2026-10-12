#pragma once
#include_next <pwd.h>

#ifdef NEED_FGETPWENT
#include <stdio.h>
struct passwd *fgetpwent(FILE *stream);
#endif
