#pragma once

#ifdef NEED_POSIX_SPAWN
#include <sys/types.h>

struct __portable_spawn_act {
	int fd, newfd;
};

typedef struct {
	struct __portable_spawn_act acts[8];
	int nacts;
} posix_spawn_file_actions_t;
typedef void *posix_spawnattr_t;

#ifdef __cplusplus
extern "C" {
#endif

int posix_spawn(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *, char *const [], char *const []);
int posix_spawnp(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *, char *const [], char *const []);

int posix_spawn_file_actions_init(posix_spawn_file_actions_t *);
int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *);
int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *, int, int);

#ifdef __cplusplus
}
#endif

#else
#include_next <spawn.h>
#endif
