// PROTOTYPE — throwaway mock data for interaction design. No daemon, no schema.
.pragma library

var now = { title: "Versus", artist: "Lifeformed", album: "Axiom Verge OST", length: 214 }
var playing = true
var position = 38
var volume = 65

var queue = [
  { title: "Versus", artist: "Lifeformed", album: "Axiom Verge OST", length: 214 },
  { title: "Apogee", artist: "Lifeformed", album: "Axiom Verge OST", length: 261 },
  { title: "Gerudo Valley", artist: "Koji Kondo", album: "Ocarina of Time OST", length: 271 },
  { title: "Song of Storms", artist: "Koji Kondo", album: "Ocarina of Time OST", length: 90 },
  { title: "Lake Hylia", artist: "Koji Kondo", album: "Ocarina of Time OST", length: 227 },
  { title: "Tavern", artist: "Lifeformed", album: "Axiom Verge OST", length: 189 }
]

var artists = [
  {
    name: "Lifeformed",
    albums: [
      { title: "Axiom Verge OST", year: 2015, tracks: [
        { title: "Thrush", length: 203 }, { title: "Versus", length: 214 },
        { title: "Apogee", length: 261 }, { title: "Tavern", length: 189 },
        { title: "Epithet", length: 245 } ] },
      { title: "Dustforce OST", year: 2012, tracks: [
        { title: "Cidertime", length: 154 }, { title: "Windfall", length: 232 } ] }
    ]
  },
  {
    name: "Koji Kondo",
    albums: [
      { title: "Ocarina of Time OST", year: 1998, tracks: [
        { title: "Title Theme", length: 184 }, { title: "Gerudo Valley", length: 271 },
        { title: "Song of Storms", length: 90 }, { title: "Lake Hylia", length: 227 } ] },
      { title: "Super Mario World OST", year: 1990, tracks: [
        { title: "Overworld", length: 130 }, { title: "Athletic", length: 118 } ] }
    ]
  },
  {
    name: "Disasterpeace",
    albums: [
      { title: "Fez OST", year: 2012, tracks: [
        { title: "Adventure", length: 245 }, { title: "Sync", length: 198 },
        { title: "Glacier", length: 302 } ] }
    ]
  }
]

var playlists = [
  { name: "Morning Coffee", tracks: [queue[0], queue[2], queue[5]] },
  { name: "Focus Deep", tracks: [queue[1], queue[3], queue[4]] }
]

function fmt(s) {
  if (s < 0) s = 0
  var m = Math.floor(s / 60), r = Math.floor(s % 60)
  return m + ":" + (r < 10 ? "0" : "") + r
}
