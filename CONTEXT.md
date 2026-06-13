# Kaset Domain Language

## Library

The signed-in user's saved YouTube Music collection. Kaset surfaces Library content as playlists, followed artists, subscribed podcast shows, and uploaded songs.

## Library Content Identity

The identity rules used to decide whether two Library items refer to the same saved content. YouTube Music can expose the same playlist as either a `VL...` browse ID or a raw playlist ID, and the same followed artist as either an `MPLAUC...` library browse ID or a public `UC...` channel ID. Kaset treats those equivalent forms as one Library item.
