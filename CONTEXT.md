# Kaset Domain Language

## Library

The signed-in user's saved YouTube Music collection. Kaset surfaces Library content as playlists, followed artists, subscribed podcast shows, and uploaded songs.

## Library Content Identity

The identity rules used to decide whether two Library items refer to the same saved content. YouTube Music can expose the same playlist as either a `VL...` browse ID or a raw playlist ID, and the same followed artist as either an `MPLAUC...` library browse ID or a public `UC...` channel ID. Kaset treats those equivalent forms as one Library item.

## Library Content Parsing

The parser slice that turns YouTube Music Library browse responses into Kaset Library content. It owns Library renderer traversal and item classification before handing identity equivalence to Library Content Identity.

## Library Content Reconciliation

The rules that merge optimistic local Library mutations with eventually-consistent YouTube Music Library snapshots. Kaset keeps locally added items visible and locally removed items suppressed until backend responses stabilize.

## Library Mutation Orchestration

The workflows that apply a user-requested Library change to YouTube Music, invalidate stale Library response caches, update visible Library state optimistically, and schedule reconciliation when backend snapshots lag behind the accepted mutation.
