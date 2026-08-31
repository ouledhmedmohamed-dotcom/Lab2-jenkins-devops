package com.linqiny;

   import org.junit.Test;
     import static org.junit.Assert.assertTrue;

     public class AppTest {
     @Test
     public void testGetMessage()   {
       assertTrue(App.getMessage().contains("Lab2 Jenkins"));
              }
}
