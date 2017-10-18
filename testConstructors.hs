data F = F1 | F2 | F3 | F4 | F5 | F6 | F7 | F8 | F9 | F10 deriving (Enum, Show)


data E = E1 | E2 | E3 | E4 | E5 deriving Show


{-# NOINLINE quux #-}
quux F1 = 'a'
quux F2 = 's'
quux F3 = 'd'
quux F4 = 'f'
quux F5 = 'g'
quux F6 = 'h'
quux F7 = 'j'
quux F8 = 'k'
quux F9 = 'l'
quux F10 = 'z'

{-# NOINLINE foo #-}
foo F1 = E1
foo F2 = E2
foo F3 = E3
foo F4 = E4

{-# NOINLINE baz #-}
baz F1 = E1
baz F2 = E2
baz F3 = E3
baz F4 = E4
baz F7 = E4

main = do print $ foo <$> [F1 .. F4]
          print $ quux <$> [F1 .. F10]
          print $ baz F10
