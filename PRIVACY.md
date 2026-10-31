# Pantrified Privacy Policy

Last updated: October 31, 2026

Pantrified is an iPhone app for managing household food, developed by Justin
Beeson. This policy covers the current early beta, including TestFlight builds.
Features are still being developed, so an installed build may not offer every
feature described in the project's plans.

## Information the app collects

The current app does not send personal information to the developer. It does not
require a Pantrified account and contains no advertising, analytics, tracking,
or third-party crash-reporting SDKs.

## Camera, photos and barcode scanning

Pantrified uses the camera only when you tap Scan or Add a batch, and the
camera stops when you leave that screen or the app.

**Scan** reads the number in one product barcode. It does not take, keep or
save photos or video: the camera's frames are shown on screen and decoded by
iOS, and only the barcode number reaches the app.

**Add a batch** takes photos of the food you add so the app can read their
labels: the name, a printed date, barcodes and QR codes. You can also pick
photos you already took with the iOS Photos picker, which gives the app only
the photos you pick and no other access to your library. The app keeps its own
copies of these photos in its private storage on your iPhone. They are not
saved to your photo library and are not included in device backups. A batch
you finish (by adding or deleting everything in it) keeps its photos for one
more day, so you can undo, and then they are deleted. A batch you leave
unfinished is deleted entirely, photos and everything read from them, 3 days
after you last used it (opened it, took or removed a photo, changed it or
added from it). Discarding a batch deletes it straight away. The app deletes
these while it is open: when it starts and whenever it comes back to the
screen. If you do not open Pantrified for longer than that, they are deleted
the next time you do, and deleting the app deletes them at once. The
originals in your library are never changed or deleted.
The photos are read on your iPhone and are not sent anywhere. A link in a QR
code is never opened.

What the app read from a batch's photos (their text, codes, and a numerical
summary of how each photo looks, used to group photos of the same package) is
kept and deleted with the batch's photos, as above. Once you add the food, what stays is what you added:
the name, place, printed date and barcode, as for food added by hand. No photo
is kept with your food.

A copy of a photo you pick keeps the details stored in that file, such as
where it was taken, until it is deleted. The app uses only the image and the
time it was taken.

You can turn camera access off in iOS Settings and still add food by hand or
from photos you pick.

A barcode you scan, or that the app reads from a photo, is kept with that food
in the app's storage on your device.
Apart from the product lookup below, it does not leave the device: it is not
synchronized or sent to the developer. It stays after the food is used up or
discarded, and is removed only when you delete the app.

## Product lookup

Builds that include product lookup send a barcode number, scanned or read from
a batch photo, to USDA
FoodData Central at api.nal.usda.gov, which uses the U.S. government's
api.data.gov key service, to suggest the product's name. The request contains
the barcode number, written in up to four lengths with leading zeros because
the service stores barcodes in different lengths, and the app's own access
key. It contains nothing about you, your household or your other food, and
the app sets a fixed app name and language on it instead of
your device's details. Like any internet request, it reveals your device's IP
address to the service. The app keeps no cookies or cache from it and logs
nothing about it. The service limits how many requests can come from one IP
address each hour. When it asks the app to slow down, the app stops sending
lookups for a while and saves on your device only the time when they may
resume, so that a restart does not send requests the service would refuse.
The service's handling of requests is covered by
[api.data.gov](https://api.data.gov/) and the
[FoodData Central API guide](https://fdc.nal.usda.gov/api-guide). If the lookup
finds nothing, cannot connect or is paused, you enter the name yourself.
Photos, and the text read from them, are never part of a lookup. Scanning and
batches work without a network connection.

## Information processed on your device

The app's local storage is designed to hold food inventory, storage locations,
shopping items, preferences and other household records. When a build supports
saving these records, they stay in the app's private storage on your device.
The developer cannot access that storage.

Recipe generation available in evaluation builds uses Apple's on-device
language model. Requests and results are processed on your device; the app does
not send them to the developer or a remote model service.

The current beta does not implement household cloud synchronization, recipe
lookups, cloud model generation, Reminders export, or in-app purchases. This policy must be updated when features
that change data handling are introduced.

## Apple services and beta feedback

iOS may include local app data in device backups according to your Apple
settings. Apple handles App Store and TestFlight downloads and may collect
diagnostics according to its terms and your settings.

When you use TestFlight, Apple may share beta diagnostics and feedback you
choose to send with the developer. Feedback may include your comments,
screenshots, contact information and technical details about the app and device.
The developer uses that information to investigate problems and improve the app.
Pantrified does not operate a separate diagnostics collection service.

See [Apple's privacy policy](https://www.apple.com/legal/privacy/) for information
about Apple's services.

## Keeping and deleting data

Local records remain on your device until you remove them through an available
app feature or delete the app. Using iOS's Delete App option removes the app's
local data from the device. Copies in device backups are managed separately
through your Apple settings. Offloading the app preserves its data.

Support requests and beta feedback are kept as needed to investigate and respond
to the issue. GitHub and Apple manage records held by their services under their
own policies.

## Support and contact

For support or privacy questions, use the
[Pantrified issue tracker](https://github.com/thisjustin816/pantrified/issues).
Information you provide is used to respond to your request. GitHub issues are
public: do not include private household records, dietary or health information,
personal photos, credentials, or other information you do not want published.
Beta testers can use TestFlight's feedback feature instead of opening a public
issue.

GitHub operates the issue tracker under its
[privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).

## Changes to this policy

When the app's data handling changes, this policy and its revision date will be
updated. The current policy is available in the
[Pantrified repository](https://github.com/thisjustin816/pantrified/blob/main/PRIVACY.md).
