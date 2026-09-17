import Foundation

/// The licence, carried inside the app.
///
/// MIT asks one thing in return for everything it permits: that the copyright
/// notice travels with every copy. For a binary that means the app itself has
/// to be able to show it — a `LICENSE` file left behind in a repository is not
/// included in the copy somebody downloaded.
///
/// So this is not decoration. It is the term being honoured.
enum Licence {

    static let holder = "Yogesh Gahlot"

    static let year = "2026"

    static let name = "MIT"

    static var notice: String { "Copyright © \(year) \(holder)" }

    /// The full text, matching `LICENSE` at the repository root. If one is
    /// edited, edit the other — `CopyTests` checks they agree on the terms.
    static let text = """
        MIT License

        Copyright (c) 2026 Yogesh Gahlot

        Permission is hereby granted, free of charge, to any person obtaining a copy \
        of this software and associated documentation files (the "Software"), to deal \
        in the Software without restriction, including without limitation the rights \
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
        copies of the Software, and to permit persons to whom the Software is \
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all \
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
        SOFTWARE.
        """

    /// What the app is built on, and nothing else.
    ///
    /// There are no third-party dependencies: no Swift packages, no vendored
    /// source, no bundled libraries. Everything here is either Apple's or the
    /// author's, which is why this list is short and why there is nothing
    /// inbound to acknowledge.
    static let dependencies = "No third-party code. Apple frameworks only."
}
