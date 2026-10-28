# rayobs

Donde se guardan las métricas, los logs y las trazas de las otras apps, escrito en
[raylang](https://github.com/ray-language/raylang). Hace scraping de los `/metrics` de Prometheus
(raystat, raygate…), recibe logs (las líneas JSON de `net/log`, o cualquier texto) y spans por HTTP,
los guarda en disco por horas con retención, y responde consultas por tiempo: series con `rate`, logs
por servicio, nivel, texto o traza, y una traza entera como árbol con sus logs.

```
$ rayobs serve
rayobs 0.1.0: http://127.0.0.1:9400, data in data, retention 168 h, commit window 0 ms, 2 scrape target(s)

$ rayobs ship --service raystat -- ./raystat serve      # su salida pasa, y cada línea llega como log
$ rayobs logs --service raystat --level error --since 1h
$ rayobs query 'raystat_lines_total' --fn rate --step 1m --since 1h --sum
$ rayobs trace 0123456789abcdef0123456789abcdef
front GET /                          |████████████████████████████████████████| 40 ms
  api query                          |     ████████████████████               | 20 ms error

2026-10-28T23:10:56Z ERROR api: query timed out
```

```
rayobs serve [--config rayobs.toml]
rayobs ship --service NAME [--api URL] -- COMMAND [ARGS…]
rayobs logs [--service S] [--trace ID] [--level L] [--grep TEXT] [--since 1h] [--limit 100]
rayobs trace ID [--since 1d]
rayobs query 'name{k="v"}' [--fn last|avg|min|max|rate] [--step 1m] [--since 1h] [--sum]
rayobs blast [--api URL] [-n LINES] [-c CLIENTS] [-b LINES_PER_REQUEST]
```

## Estado

| Qué | Estado |
|---|---|
| Scraping de Prometheus por objetivo, con `job`/`instance`, `up`, `scrape_duration_seconds`, `scrape_samples` | ✅ |
| Push de una página de exposición (`POST /v1/metrics?job=`) | ✅ |
| Consultas por rango: `last`, `avg`, `min`, `max`, `rate` (con reinicios de contador), `sum` entre series | ✅ |
| Logs: JSON de `net/log` (nivel normalizado), o texto; por servicio, nivel, `trace_id`, texto, tiempo | ✅ |
| `rayobs ship`: lanza un programa, pasa su salida y la envía; reenvía SIGTERM/SIGINT al hijo | ✅ |
| Spans por HTTP (array JSON o NDJSON); una traza como árbol (profundidad por `parent_id`) con sus logs | ✅ |
| Almacén por horas, solo de añadir, con retención; commit agrupado (una sincronización por tanda) | ✅ |
| Token bearer para todo el API | ✅ |
| Alertas con escalado y guardias (lo que le falta a raywatch) | ➖ v2 |
| Índices dentro de un segmento, compresión, varias réplicas | ➖ v2 |
| Que raycall, raygate y raylb envíen sus spans | ➖ v2 (hoy propagan `traceparent` y nadie los exporta) |

Pruebas: 6 tests (`make test`, `make test-native`), en VM y nativo. Y `make interop` (8
comprobaciones) con el binario real de raystat: corre bajo `rayobs ship`, rayobs le hace scraping cada
segundo, `raystat blast` le manda 32 000 líneas statsd, y el contador guardado tiene que crecer
exactamente 32 000. Además llegan sus logs, una traza vuelve como árbol, y al parar `ship` se para
raystat y `up` pasa a 0.

## Cómo

```
src/main.ray     la línea de órdenes: serve, ship, logs, trace, query, blast
src/config.ray   rayobs.toml: dirección, datos, retención, objetivos
src/server.ray   todo junto: un escritor por señal, un scraper por objetivo, el API
src/api.ray      el API (JSON)
src/store.ray    el almacén: segmentos por hora, el escritor con commit agrupado, el escaneo
src/ingest.ray   de lo que llega a registros: logs, spans, páginas de exposición
src/prom.ray     el formato de exposición de Prometheus
src/metrics.ray  las consultas de series
src/scrape.ray   el scraping
```

- **Un archivo por señal y por hora** (`data/logs/2026102823.seg`), solo de añadir. Cada línea es
  `ts TAB a TAB b TAB cuerpo`: el servicio y la traza (o el nombre y las etiquetas de una métrica)
  van delante, para filtrar sin parsear el JSON. Una consulta abre solo las horas de su intervalo, y
  la retención borra horas enteras.
- **Una fibra escribe cada señal, con commit agrupado.** Toma una petición, añade todo lo que esté ya
  en cola, escribe una vez por segmento, sincroniza una vez (`fs.sync_data`) y solo entonces contesta
  a todos. Lo que llega mientras dura una sincronización va en la siguiente, así que con carga las
  tandas crecen solas (unos 2 000 registros por sincronización). La primera versión esperaba además
  una ventana fija de 50 ms, y salía entre 3 y 70 veces más lenta; queda como opción (`commit_ms`).
- **Las lecturas no pasan por el escritor**: el handler lee los archivos. Lo que se ha confirmado ya
  está sincronizado, así que se ve.
- **Los logs se guardan con las claves ordenadas y el nivel en minúsculas** (`net/log` escribe
  `INFO`): filtrar por nivel es buscar un texto exacto.
- **Un `rate`** suma los incrementos de un contador en el paso (una bajada cuenta como reinicio desde
  0) y los divide por el tiempo entre la primera muestra y la última.

## Rendimiento

`make bench` (scripts/bench.sh): binario nativo con raylang 1.27.85 en un MacBook (Apple Silicon).
Cada petición es un POST de N líneas JSON y no se contesta hasta que están sincronizadas:

| clientes × líneas por petición | líneas/s | con ventana fija de 50 ms |
|---|---:|---:|
| 1 × 100 | 131 k | 1,8 k |
| 1 × 500 | 177 k | 8,2 k |
| 8 × 500 | 718 k | 65 k |
| 32 × 500 | 962 k | 247 k |
| 32 × 5000 | 919 k | 867 k |

2,95 M de registros en 1 487 sincronizaciones, con 337 MiB de RSS como máximo (las peticiones de 5000
líneas en vuelo). Una consulta de logs por servicio sobre 1,6 M de líneas (209 MB en una hora) tarda
0,35 s, y una de texto 0,14 s: se lee el segmento entero, porque todavía no hay índice.

La sincronización es `fs.sync_data`. En macOS no fuerza la caché del disco como `F_FULLFSYNC` (que es
`fs.sync`, unas 150 veces más caro en APFS). Protege de una caída del proceso o del sistema, no de un
corte de luz con la caché del disco sin vaciar.

## Hallazgos de dogfood

En `../findings/open/rayobs-1.27.85.md`:

- **#291 [B] nativo**: un brazo de `match` con guarda, en una función que devuelve `webserver.Response`,
  no compila (E0382). Rodeo en `src/api.ray`: un `if` dentro del brazo `_`.
- **#292 [B] nativo**: un struct con un campo `[Channel<T>]`, en un programa sin operaciones de canal,
  no compila (`__RayChan`). Salió al reducir #291.
- **#293 [E] net**: `log.emit` pone la hora con resolución de segundos.
- **#294 [E]**: un `for` como cuerpo de un brazo de `match` es un error de sintaxis que no dice que
  faltan llaves (cinco veces en las cuatro apps de esta tanda).
- **#295 [D]**: `ray doc Proc.kill` no encuentra los métodos que vienen de un trait.

Lo que salió bien: `process.cmd(...).stream()` con `merge_output` hizo `ship` en 40 líneas;
`select_timeout` + `try_recv` dieron el commit agrupado; y el contador de raystat que guarda rayobs
coincidió exactamente con lo que se envió.
