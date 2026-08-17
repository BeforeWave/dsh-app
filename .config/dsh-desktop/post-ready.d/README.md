# post-ready.d

Place executable `.sh` files here to run after the DSH Web health check succeeds.

Example:

```bash
#!/bin/bash
osascript -e 'display notification "DSH is ready" with title "DS Harness"'
```
