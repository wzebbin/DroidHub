#include <dirent.h>
#include <errno.h>
#include <stdbool.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/fs.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

static bool matches_identity(const struct stat *entry, const char *expected) {
    char identity[64];
    snprintf(identity, sizeof(identity), "%ju:%ju", (uintmax_t)entry->st_dev, (uintmax_t)entry->st_ino);
    return strcmp(identity, expected) == 0;
}

static bool same_entry(const struct stat *left, const struct stat *right) {
    return left->st_dev == right->st_dev && left->st_ino == right->st_ino;
}

static bool remove_entry(int parent, const char *name, const struct stat *expected, unsigned depth) {
    struct stat current;
    if (fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) != 0 || !same_entry(&current, expected)) return false;
    if (!S_ISDIR(current.st_mode)) return unlinkat(parent, name, 0) == 0;
    if (depth >= 256) return false;

    int child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (child < 0) return false;
    if (fstat(child, &current) != 0 || !same_entry(&current, expected)) {
        close(child);
        return false;
    }
    DIR *directory = fdopendir(child);
    if (directory == NULL) {
        close(child);
        return false;
    }
    bool complete = true;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (entry == NULL) {
            complete = errno == 0;
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        struct stat item;
        if (fstatat(child, entry->d_name, &item, AT_SYMLINK_NOFOLLOW) != 0 ||
            item.st_dev != expected->st_dev || !remove_entry(child, entry->d_name, &item, depth + 1)) {
            complete = false;
            break;
        }
    }
    closedir(directory);
    return complete && fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
           same_entry(&current, expected) && unlinkat(parent, name, AT_REMOVEDIR) == 0;
}

static int delete_trash_item(const char *path, const char *name, const char *parent_id, const char *item_id) {
    if (path[0] != '/' || name[0] == '\0' || strchr(name, '/') != NULL ||
        strcmp(name, ".") == 0 || strcmp(name, "..") == 0) return 2;
    int parent = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (parent < 0) return 1;
    struct stat root, item;
    bool safe = fstat(parent, &root) == 0 && matches_identity(&root, parent_id) &&
                fstatat(parent, name, &item, AT_SYMLINK_NOFOLLOW) == 0 &&
                item.st_dev == root.st_dev && matches_identity(&item, item_id);
    bool removed = safe && remove_entry(parent, name, &item, 0);
    close(parent);
    return removed ? 0 : 1;
}

// A single rename syscall never copies across volumes or replaces a destination.
int main(int argc, char **argv) {
    if (argc == 6 && strcmp(argv[1], "--delete") == 0)
        return delete_trash_item(argv[2], argv[3], argv[4], argv[5]);
    if (argc != 4 || argv[1][0] != '/' || argv[2][0] != '/') return 2;
    struct stat source;
    if (lstat(argv[1], &source) != 0) {
        puts(errno == EACCES || errno == EPERM ? "denied" : "source-changed");
        return 0;
    }
    if (!matches_identity(&source, argv[3])) {
        puts("source-changed");
        return 0;
    }
    if (syscall(SYS_renameat2, AT_FDCWD, argv[1], AT_FDCWD, argv[2], RENAME_NOREPLACE) == 0) {
        puts("moved");
        return 0;
    }
    switch (errno) {
        case EEXIST: case ENOTEMPTY: puts("exists"); break;
        case EXDEV: puts("cross-volume"); break;
        case EACCES: case EPERM: case EROFS: puts("denied"); break;
        case ENOENT: case ENOTDIR: puts("path-changed"); break;
        case ENOSYS: case EINVAL: case EOPNOTSUPP: puts("unsupported"); break;
        case ENOSPC: case EDQUOT: puts("no-space"); break;
        default: puts("failed"); break;
    }
    return 0;
}
