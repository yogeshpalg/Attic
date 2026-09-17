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

    /// What the licence does not cover.
    ///
    /// MIT is a copyright licence and says nothing about names. It grants the
    /// right to copy, change and sell the *code* — not the right to call the
    /// result Attic, or to use the mark in a way that suggests the author
    /// stands behind it. Apache 2.0 spells this out in its own section; MIT
    /// leaves it to be said, so it is said here and in the README.
    ///
    /// This is not a restriction on forking. Fork it, sell it, rename it. The
    /// ask is a different name on the result, which is the same thing the
    /// copyright notice asks for: that credit stays attached to who did what.
    static let trademark = """
        The MIT licence covers the source. The name "Attic" and the app's mark \
        are not part of that grant: a fork is welcome, under its own name, \
        without implying the author endorses it.
        """

    /// What the app is built on, and nothing else.
    ///
    /// There are no third-party dependencies: no Swift packages, no vendored
    /// source, no bundled libraries. Everything here is either Apple's or the
    /// author's, which is why this list is short and why there is nothing
    /// inbound to acknowledge.
    static let dependencies = "No third-party code. Apple frameworks only."
}
