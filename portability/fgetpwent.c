#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pwd.h>

static char *__pw_strfield(char **sp)
{
	char *p, *s = *sp;
	*sp = NULL;
	if (!s || !*s) return (char *) "";
	p = strchr(s, ':');
	if (p) {
		*p = 0;
		*sp = p + 1;
	}
	return s;
}

static unsigned long __pw_numfield(char **sp)
{
	return strtoul(__pw_strfield(sp), NULL, 10);
}

struct passwd *fgetpwent(FILE *stream)
{
	static char *line;
	static size_t line_len;
	static struct passwd pwd;
	ssize_t len;

	while ((len = getline(&line, &line_len, stream)) > 0) {
		char *s = line;
		if (line[len-1] == '\n') line[--len] = 0;
		if (!len || line[0] == '#') continue;
		pwd.pw_name = __pw_strfield(&s);
		pwd.pw_passwd = __pw_strfield(&s);
		pwd.pw_uid = __pw_numfield(&s);
		pwd.pw_gid = __pw_numfield(&s);
		pwd.pw_gecos = __pw_strfield(&s);
		pwd.pw_dir = __pw_strfield(&s);
		pwd.pw_shell = __pw_strfield(&s);
		return &pwd;
	}
	return NULL;
}
