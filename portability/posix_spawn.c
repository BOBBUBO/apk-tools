#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <spawn.h>

int posix_spawn_file_actions_init(posix_spawn_file_actions_t *act)
{
	act->nacts = 0;
	return 0;
}

int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *act)
{
	return 0;
}

int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *act, int fd, int newfd)
{
	if (act->nacts >= (int)(sizeof act->acts / sizeof act->acts[0])) return ENOMEM;
	act->acts[act->nacts++] = (struct __portable_spawn_act) { fd, newfd };
	return 0;
}

static const char *__portable_spawn_get_path(char *const envp[])
{
	if (!envp) return NULL;
	for (char *const *e = envp; *e; e++)
		if (strncmp(*e, "PATH=", 5) == 0) return *e + 5;
	return NULL;
}

static int __portable_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *act, int use_path, char *const argv[], char *const envp[])
{
	pid_t child = fork();
	if (child < 0) return errno;
	if (child == 0) {
		if (act)
			for (int i = 0; i < act->nacts; i++)
				dup2(act->acts[i].fd, act->acts[i].newfd);
		if (use_path && !strchr(path, '/')) {
			const char *search = __portable_spawn_get_path(envp) ?: "/usr/bin:/bin";
			char buf[4096];
			for (char *sep; path[0]; ) {
				size_t len = (sep = strchrnul(search, ':')) - search;
				if (len == 0) { search = "."; len = 1; }
				snprintf(buf, sizeof buf, "%.*s/%s", (int) len, search, path);
				execve(buf, argv, envp);
				if (!sep || !*sep) break;
				search = sep + 1;
			}
		}
		execve(path, argv, envp);
		_exit(127);
	}
	*pid = child;
	return 0;
}

int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *act, const posix_spawnattr_t *attr, char *const argv[], char *const envp[])
{
	return __portable_spawn(pid, path, act, 0, argv, envp);
}

int posix_spawnp(pid_t *pid, const char *path, const posix_spawn_file_actions_t *act, const posix_spawnattr_t *attr, char *const argv[], char *const envp[])
{
	return __portable_spawn(pid, path, act, 1, argv, envp);
}
