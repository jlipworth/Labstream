/// Wire-shape facts shared by Jellyfin and Emby's universal audio-stream endpoint.
/// Keep the value and ordering stable: both servers use this allowlist to decide whether
/// a source can direct-play or must be transcoded to HLS/AAC.
enum MediaBrowserAudioStreamFacts {
    static let directPlayContainers = "mp3,aac,m4a,m4b,flac,alac,wav,ogg,oga,opus,webma"
}
