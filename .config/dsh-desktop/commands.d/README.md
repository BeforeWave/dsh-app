# commands.d

Executable `.sh` files in this directory can become DS Harness menu actions.

Supported metadata:

```bash
# @menu Restart Backend
# @shortcut cmd+shift+r
# @order 10
# @separator before
# @enabled true
```

The shell body is executed when the menu item is selected.
