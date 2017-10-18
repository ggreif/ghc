data Small = S1 | S2 | S3 | S4 deriving Show

data Big = B1 | B2 | B3 | B4 | B5 | B6 | B7 | B8 | B9 | B10 deriving Show

{-# NOINLINE quux #-}
quux B1 = 'a'
quux B2 = 'b'
quux B3 = 'c'
quux B4 = 'd'
quux B5 = 'e'
quux B6 = 'f'
quux B7 = 'g'
quux B8 = 'h'
quux B9 = 'i'
quux B10 = 'j'


{-# NOINLINE foo #-}
foo B1 = S1
foo B2 = S2
foo B3 = S3
foo B4 = S4


{-# NOINLINE bar #-}
bar S1 = B1
bar S2 = B2
bar S3 = B3
bar S4 = B4


main = do print $ foo B3
          print $ bar S3
          print $ quux B9
