//! Where the library's vectors are measured from.
//!
//! A sentence encoder does not spread its output over the sphere. Nearly all
//! of what it writes for one library is a single direction shared by every
//! title - that these are film descriptions, in French, of about this length -
//! and the part that tells two films apart is what is left after it. On this
//! library the shared direction is 91% of every vector, which is why raw
//! cosines here all sit near +0.836 with a spread of 0.018: the number is
//! nine parts agreement about the language and one part taste.
//!
//! Subtracting it is the whole of this module. What remains has a mean cosine
//! of 0.000 and a spread of 0.080, and every rule written against a
//! distribution - a mean, a spread, an extreme - starts meaning what it says
//! again. The size of the shared component is the one thing that differs
//! wildly between encoders, so removing it is also what lets one rule outlive
//! the model that it was first measured on.
//!
//! Nothing is materialised per pair. The centred cosine of two titles is
//! their raw dot product plus a handful of per-title scalars, so the hot loop
//! keeps its integer dot product and the library costs three floats a title
//! rather than a second copy of every vector.

use crate::index::db::TitleVector;

/// The library's vectors, re-centred on their own mean direction.
pub struct Space {
    /// The direction every title shares: the mean of the unit vectors.
    mean: Vec<f32>,
    mean_sq: f32,
    /// `|x|`, per title, in the order `vectors` came in.
    norm: Vec<f32>,
    /// `x/|x| . mean`, per title: how much of this title is the shared
    /// direction.
    along: Vec<f32>,
    /// `|x/|x| - mean|`, per title: what is left once the shared direction is
    /// taken out, and the length the centred vector is scaled back from. Zero
    /// for a title that is the shared direction and nothing else, which has no
    /// centred direction to speak of.
    radius: Vec<f32>,
}

impl Space {
    /// Measures the shared direction and everything that follows from it, in
    /// one pass over the library. Vectors of a length the majority does not
    /// share are left with a zero radius and take no part: they cannot be
    /// compared with the rest anyway.
    pub fn of(vectors: &[TitleVector]) -> Space {
        let dims = vectors.first().map_or(0, |v| v.vector.len());
        let mut mean = vec![0.0f32; dims];
        let mut norm = Vec::with_capacity(vectors.len());
        let mut counted = 0u32;
        for v in vectors {
            let n = v
                .vector
                .iter()
                .map(|a| f32::from(*a) * f32::from(*a))
                .sum::<f32>()
                .sqrt();
            norm.push(n);
            if v.vector.len() != dims || n <= 0.0 {
                continue;
            }
            for (m, a) in mean.iter_mut().zip(&v.vector) {
                *m += f32::from(*a) / n;
            }
            counted += 1;
        }
        if counted > 0 {
            for m in &mut mean {
                *m /= counted as f32;
            }
        }
        let mean_sq: f32 = mean.iter().map(|m| m * m).sum();

        let mut along = Vec::with_capacity(vectors.len());
        let mut radius = Vec::with_capacity(vectors.len());
        for (i, v) in vectors.iter().enumerate() {
            if v.vector.len() != dims || norm[i] <= 0.0 {
                along.push(0.0);
                radius.push(0.0);
                continue;
            }
            let a: f32 = v
                .vector
                .iter()
                .zip(&mean)
                .map(|(x, m)| f32::from(*x) * m)
                .sum::<f32>()
                / norm[i];
            along.push(a);
            radius.push((1.0 - 2.0 * a + mean_sq).max(0.0).sqrt());
        }
        Space {
            mean,
            mean_sq,
            norm,
            along,
            radius,
        }
    }

    /// Whether this title has a direction of its own once the shared one is
    /// removed. A title that has not is nobody's neighbour and no taste's
    /// member, rather than being everybody's at a cosine of not-a-number.
    pub fn placed(&self, i: usize) -> bool {
        self.radius[i] > 0.0
    }

    /// The centred cosine of two library titles, given the raw dot product of
    /// their stored vectors. The caller computes that dot however it likes -
    /// in integers, over quantised bytes - and this puts it in the centred
    /// space without touching either vector again.
    pub fn cos(&self, a: usize, b: usize, dot: f32) -> f32 {
        let r = self.radius[a] * self.radius[b];
        if r <= 0.0 {
            return 0.0;
        }
        (dot / (self.norm[a] * self.norm[b]) - self.along[a] - self.along[b] + self.mean_sq) / r
    }

    /// The centred cosine of a library title to an arbitrary centred unit
    /// direction, given the raw dot product of the stored vector with it and
    /// that direction's own share of the mean (see `along_mean`). This is what
    /// a taste's centre is compared against: a direction the library does not
    /// hold a vector for.
    pub fn cos_to(&self, i: usize, dot: f32, along_mean: f32) -> f32 {
        if self.radius[i] <= 0.0 {
            return 0.0;
        }
        (dot / self.norm[i] - along_mean) / self.radius[i]
    }

    /// How much of a direction is the shared one: the second argument
    /// `cos_to` wants, computed once per direction rather than per title.
    pub fn along_mean(&self, dir: &[f32]) -> f32 {
        dir.iter().zip(&self.mean).map(|(d, m)| d * m).sum()
    }

    /// A vector the library does not hold as a centred unit direction: a
    /// query the encoder was asked for, a seasonal anchor. The same two steps
    /// `unit` takes for a title - scale to length one, subtract the direction
    /// every title shares - with its own norm rather than a stored one. None
    /// when the shared direction is all there is to it, which is the same
    /// answer `placed` gives about a title.
    pub fn direction_of(&self, vector: &[i8]) -> Option<Vec<f32>> {
        if vector.len() != self.mean.len() {
            return None;
        }
        let norm = vector
            .iter()
            .map(|a| f32::from(*a) * f32::from(*a))
            .sum::<f32>()
            .sqrt();
        if norm <= 0.0 {
            return None;
        }
        let mut centred: Vec<f32> = vector
            .iter()
            .zip(&self.mean)
            .map(|(x, m)| f32::from(*x) / norm - m)
            .collect();
        let radius = centred.iter().map(|x| x * x).sum::<f32>().sqrt();
        if radius <= 0.0 {
            return None;
        }
        for x in centred.iter_mut() {
            *x /= radius;
        }
        Some(centred)
    }

    /// One title as a centred unit vector, for the few places that need the
    /// vector itself rather than a cosine against it - the taste fingerprint
    /// averages its members, and an average needs coordinates. Empty for a
    /// title `placed` says has no direction.
    pub fn unit(&self, i: usize, v: &TitleVector) -> Vec<f32> {
        if self.radius[i] <= 0.0 {
            return Vec::new();
        }
        v.vector
            .iter()
            .zip(&self.mean)
            .map(|(x, m)| (f32::from(*x) / self.norm[i] - m) / self.radius[i])
            .collect()
    }
}
