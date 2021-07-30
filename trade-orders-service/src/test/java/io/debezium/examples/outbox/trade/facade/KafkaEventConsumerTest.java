package io.debezium.examples.outbox.trade.facade;

import io.quarkus.test.common.QuarkusTestResource;
import io.quarkus.test.common.QuarkusTestResourceLifecycleManager;
import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.junit.mockito.InjectMock;
import io.smallrye.reactive.messaging.connectors.InMemoryConnector;
import io.smallrye.reactive.messaging.kafka.KafkaRecord;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mockito;

import javax.inject.Inject;

import java.io.IOException;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.ExecutionException;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.when;

@QuarkusTest
@QuarkusTestResource(KafkaEventConsumerTest.KafkalessSmallrye.class)
class KafkaEventConsumerTest {
  
  @InjectMock
  OrderEventHandler mockOrderEventHandler;
  
  @Inject 
  KafkaEventConsumer kafkaEventConsumer;
  
  @SuppressWarnings("unchecked")
  @Test
  void testThatConsumerAcksMessages() throws IOException, ExecutionException, InterruptedException {
    KafkaRecord<String, String> mockRecord = Mockito.mock(KafkaRecord.class);
    when(mockRecord.getPayload()).thenReturn("MockPayload");
    
    CompletionStage<Void> completionStage = kafkaEventConsumer.onMessage(mockRecord);
    
    //Use .get to synchronously await completion.
    completionStage.toCompletableFuture().get();
    
    Mockito.verify(mockRecord).ack();
  }
  
  //Override orders channel to refer to an in memory Smallrye channel, to prevent attempts to connect to Kafka in a unit test
  public static class KafkalessSmallrye implements QuarkusTestResourceLifecycleManager {
    
    @Override
    public Map<String, String> start() {
      return InMemoryConnector.switchIncomingChannelsToInMemory("orders");
    }

    @Override
    public void stop() {
      InMemoryConnector.clear();
    }
  }
}