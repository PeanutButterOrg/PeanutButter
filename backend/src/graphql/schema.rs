use async_graphql::{EmptySubscription, Schema};

use super::{Mutation, Query};
use crate::AppState;

pub type AppSchema = Schema<Query, Mutation, EmptySubscription>;

pub fn build_schema(state: AppState) -> AppSchema {
    Schema::build(Query, Mutation, EmptySubscription)
        .data(state)
        // Far past any app query; stops a runaway nested one tying up the database.
        .limit_depth(24)
        .finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The apps ask for "More like this" with exactly this shape.
    #[test]
    fn schema_has_more_like_this() {
        let sdl = Schema::build(Query, Mutation, EmptySubscription).finish().sdl();
        assert!(
            sdl.contains("similarTitles(titleId: UUID!, limit: Int): [Title!]!"),
            "similarTitles missing or changed in the schema"
        );
    }
}
