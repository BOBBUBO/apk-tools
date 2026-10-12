#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <grp.h>

static char *__gr_strfield(char **sp)
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

struct group *fgetgrent(FILE *stream)
{
	static char *line;
	static size_t line_len;
	static struct group grp;
	static char **members;
	static size_t members_size;
	ssize_t len;

	while ((len = getline(&line, &line_len, stream)) > 0) {
		char *s = line, *m;
		size_t n = 0;

		if (line[len-1] == '\n') line[--len] = 0;
		if (!len || line[0] == '#') continue;
		grp.gr_name = __gr_strfield(&s);
		grp.gr_passwd = __gr_strfield(&s);
		grp.gr_gid = strtoul(__gr_strfield(&s), NULL, 10);
		for (m = s; m && *m; n++) {
			if (n + 2 > members_size) {
				members_size = members_size ? members_size * 2 : 16;
				members = realloc(members, members_size * sizeof members[0]);
				if (!members) return NULL;
			}
			members[n] = strsep(&s, ",");
		}
		if (n + 1 > members_size) {
			members_size = n + 1;
			members = realloc(members, members_size * sizeof members[0]);
			if (!members) return NULL;
		}
		members[n] = NULL;
		grp.gr_mem = members;
		return &grp;
	}
	return NULL;
}
